import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


SOURCE = "a586e950776cff46d618a30e890eca9add5dc13d"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    system = platform.system()
    assert os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    assert system in ("Darwin", "Windows")
    authorization = "macos-disposable-vm" if system == "Darwin" else "windows-disposable-vm"
    assert os.environ.get("FERAIL_OS_INPUT_AUTHORIZED") == authorization
    repo = Path.cwd()
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    assert source == SOURCE
    output = repo / "screenshots" / "native-os-keyboard"
    output.mkdir(parents=True, exist_ok=False)
    fixture = Path(os.environ["RUNNER_TEMP"]) / "ferail-native-os-keyboard"
    initial, target = fixture / "initial", fixture / "target"
    initial.mkdir(exist_ok=False)
    target.mkdir()
    names = ["01-first.txt", "02-second.txt", "03-third.txt"]
    for name in names:
        (target / name).write_text(f"Synthetic qualification file: {name}\n")
    if system == "Darwin":
        config = Path.home() / "Library" / "Application Support" / "Ferail"
        binary = repo / "target" / "debug" / "ferail-gpui"
        helper = fixture / "native-key"
    else:
        config = Path(os.environ["APPDATA"]) / "Ferail"
        binary = repo / "target" / "debug" / "ferail-gpui.exe"
        helper = repo.parent / "qa" / ".github" / "qa" / "native-os-keyboard-windows.ps1"
    assert not config.exists(), f"Refusing an existing Ferail profile: {config}"
    config.mkdir(parents=True)
    manifest = {
        "source": source,
        "workflow_revision": os.environ["GITHUB_SHA"],
        "platform": platform.platform(),
        "machine": platform.machine(),
        "binary_sha256": digest(binary),
        "helper_sha256": digest(helper),
        "input_api": "CGEventPostToPid" if system == "Darwin" else "SendInput",
        "physical_keyboard_tested": False,
        "cases": [],
    }
    try:
        for preference in ("missing", "true", "false"):
            case = output / preference
            state = (f"last_dir={initial}\nlanguage=en\ntheme_pref=dark\nview_mode=list\n"
                     "update_check=false\nant_trail_enabled=false\nbrowse_enabled=false\n")
            if preference != "missing":
                state += f"select_first_item={preference}\n"
            (config / "gpui-state.txt").write_text(state)
            record = {"preference": preference, "behavior_verified": False}
            manifest["cases"].append(record)
            if system == "Darwin":
                case.mkdir()
                with (case / "app.log").open("wb") as app_log:
                    app = subprocess.Popen([str(binary), "--navigate", str(target), "--view", "list",
                                            "--theme", "dark", "--width", "1400", "--height", "900"],
                                           stdout=app_log, stderr=subprocess.STDOUT)
                    record["pid"] = app.pid
                    try:
                        with (case / "helper.jsonl").open("wb") as log:
                            result = subprocess.run([str(helper), str(app.pid), str(binary), str(case)],
                                                    stdout=log, stderr=subprocess.STDOUT, timeout=60)
                        record["helper_returncode"] = result.returncode
                        assert result.returncode == 0
                    finally:
                        if app.poll() is None:
                            with (case / "close.jsonl").open("wb") as log:
                                result = subprocess.run([str(helper), "--close", str(app.pid), str(binary)],
                                                        stdout=log, stderr=subprocess.STDOUT, timeout=45)
                            record["close_returncode"] = result.returncode
                            assert result.returncode == 0
                        record["app_exit_code"] = app.wait(timeout=20)
                        assert record["app_exit_code"] == 0
            else:
                with (output / f"{preference}.log").open("wb") as log:
                    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(helper),
                                             "-Executable", str(binary), "-Target", str(target),
                                             "-Output", str(case), "-SendDown"],
                                            stdout=log, stderr=subprocess.STDOUT, timeout=90)
                record["helper_returncode"] = result.returncode
                assert result.returncode == 0
                native = json.loads((case / "manifest.json").read_text(encoding="utf-8-sig"))
                assert native["send_input_count"] == 2 and native["app_exit_code"] == 0
                record["native"] = native
            saved = (config / "gpui-state.txt").read_text()
            (case / "saved-state.txt").write_text(saved)
            (case / "seed-state.txt").write_text(state)
            preference_lines = [line for line in saved.splitlines() if line.startswith("select_first_item=")]
            assert preference_lines == ([] if preference == "missing" else [f"select_first_item={preference}"])
            directories = [line.partition("=")[2] for line in saved.splitlines() if line.startswith("last_dir=")]
            assert len(directories) == 1 and Path(directories[0]).samefile(target)
            record["preference_preserved"] = True
            record["live_session_saved_to_target"] = True
            record["images"] = []
            for name in ("initial", "down"):
                file = case / f"{name}.png"
                assert file.is_file() and file.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
                record["images"].append({"path": str(file.relative_to(output)), "sha256": digest(file)})
            record["expected_initial"] = [] if preference == "false" else [names[0]]
            record["expected_after_down"] = [names[0]] if preference == "false" else [names[1]]
            record["captures_complete"] = True
        manifest["status"] = "captured; independent visual review required"
    finally:
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
