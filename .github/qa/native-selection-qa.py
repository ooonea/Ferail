#!/usr/bin/env python3
"""Capture the existing selection CLI on a disposable GitHub-hosted runner."""

import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys


SOURCE = "412812228654faa21d08031ad0e9566303f3739d"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise SystemExit("Only disposable GitHub-hosted runners are supported")
    system = platform.system()
    if system not in ("Darwin", "Windows"):
        raise SystemExit("Native macOS or Windows is required")
    expected_arch = "arm64" if system == "Darwin" else "AMD64"
    if platform.machine() != expected_arch:
        raise SystemExit(f"Unexpected native architecture: {platform.machine()}")
    repo = Path.cwd()
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if source != SOURCE:
        raise SystemExit(f"Unexpected source revision: {source}")
    output = repo / "screenshots" / "native-selection-qa"
    output.mkdir(parents=True, exist_ok=False)
    fixture = Path(os.environ["RUNNER_TEMP"]) / "ferail-native-selection-qa"
    initial, target = fixture / "initial", fixture / "target"
    initial.mkdir(parents=True, exist_ok=False)
    target.mkdir()
    names = ["01-first.txt", "02-second.txt", "03-third.txt"]
    for name in names:
        (target / name).write_text(f"Synthetic qualification file: {name}\n")
    if system == "Darwin":
        config = Path.home() / "Library" / "Application Support" / "Ferail"
        binary = repo / "target" / "debug" / "ferail-gpui"
    else:
        config = Path(os.environ["APPDATA"]) / "Ferail"
        binary = repo / "target" / "debug" / "ferail-gpui.exe"
    if config.exists():
        raise SystemExit(f"Refusing an existing Ferail profile: {config}")
    config.mkdir(parents=True)
    manifest = {
        "source": source,
        "workflow_revision": os.environ.get("GITHUB_SHA"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "runner_arch": os.environ.get("RUNNER_ARCH"),
        "runner_image": os.environ.get("ImageVersion"),
        "binary_sha256": digest(binary),
        "status": "captures pending visual review",
        "cases": [],
    }
    failed = False
    for preference in ("missing", "true", "false"):
        for down in (False, True):
            case = f"{preference}-{'down' if down else 'initial'}"
            state = f"last_dir={initial}\nlanguage=en\nview_mode=list\n"
            if preference != "missing":
                state += f"select_first_item={preference}\n"
            (config / "gpui-state.txt").write_text(state)
            image = output / f"{case}.png"
            command = [str(binary), "--screenshot", str(image), "--navigate", str(target),
                       "--view", "list", "--theme", "dark", "--width", "1400",
                       "--height", "900", "--unsafe-real-data"]
            if down:
                command += ["--keys", "focus-shell down"]
            expected = ([names[0]] if down else []) if preference == "false" else [names[int(down)]]
            record = {"case": case, "expected_selected_names": expected, "command": command}
            (output / f"{case}-seed.txt").write_text(state)
            with (output / f"{case}.log").open("wb") as log:
                try:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                    record["returncode"] = result.returncode
                except subprocess.TimeoutExpired:
                    record["error"] = "90-second capture deadline exceeded"
            saved = config / "gpui-state.txt"
            if saved.is_file():
                (output / f"{case}-saved.txt").write_bytes(saved.read_bytes())
            valid = record.get("returncode") == 0 and image.is_file()
            if valid:
                header = image.read_bytes()[:24]
                valid = header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) == 24
                if valid:
                    record["dimensions"] = struct.unpack(">II", header[16:24])
                    record["image_sha256"] = digest(image)
            record["capture_complete"] = valid
            record["behavior_verified"] = False
            failed |= not valid
            manifest["cases"].append(record)
            (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"{case}: {'captured; review selection' if valid else 'CAPTURE FAILED'}", flush=True)
    print("No behavior PASS is asserted by this script; inspect all six images and logs.")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
