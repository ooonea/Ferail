import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Carbon

struct Failure: Error { let message: String }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}

func record(_ fields: [String: Any]) {
    var value = fields
    value["time"] = ISO8601DateFormatter().string(from: Date())
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

func advanceMainLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

@main
struct NativeKey {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            record(["status": "BLOCKED_OR_FAILED", "error": String(describing: error)])
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        try require(env["RUNNER_ENVIRONMENT"] == "github-hosted",
                    "Disposable GitHub-hosted runner required")
        let post = CGPreflightPostEventAccess()
        let ax = AXIsProcessTrusted()
        let capture = CGPreflightScreenCaptureAccess()
        record(["phase": "permissions", "post_event": post,
                "accessibility": ax, "screen_capture": capture])
        if CommandLine.arguments == [CommandLine.arguments[0], "--preflight"] { return }
        try require(post && ax && capture, "Required existing TCC grants unavailable; no prompt requested")
        try require(env["FERAIL_OS_INPUT_AUTHORIZED"] == "macos-disposable-vm",
                    "Explicit owner authorization must precede setting the authorization flag")
        try require(CommandLine.arguments.count == 4,
                    "Usage: native-key PID BINARY OUTPUT_DIRECTORY, or --close PID BINARY")
        let closing = CommandLine.arguments[1] == "--close"
        guard let pid = pid_t(CommandLine.arguments[closing ? 2 : 1]) else {
            throw Failure(message: "Invalid target PID")
        }
        let binary = URL(fileURLWithPath: CommandLine.arguments[closing ? 3 : 2]).resolvingSymlinksInPath()
        let deadline = Date().addingTimeInterval(30)
        var launched: NSRunningApplication?
        while Date() < deadline {
            if let candidate = NSRunningApplication(processIdentifier: pid),
               candidate.isFinishedLaunching && !candidate.isTerminated {
                launched = candidate
                break
            }
            advanceMainLoop()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let app = launched else { throw Failure(message: "Target did not finish launching") }
        try require(app.executableURL?.resolvingSymlinksInPath() == binary,
                    "PID executable mismatch")
        try require(app.activate(options: []), "Application activation refused")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        advanceMainLoop()

        func focused() throws {
            try require(!app.isTerminated && app.isActive &&
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                        "Target lost foreground focus")
            var focusedWindow: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                kAXFocusedWindowAttribute as CFString, &focusedWindow)
            try require(result == .success && focusedWindow != nil,
                        "No accessible focused window for target PID")
        }
        try focused()

        func post(_ key: CGKeyCode, flags: CGEventFlags) throws {
            try focused()
            try require(CGPreflightPostEventAccess(), "Posting permission changed")
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
                throw Failure(message: "Cannot construct native key pair")
            }
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            down.postToPid(pid)
            up.postToPid(pid)
            record(["phase": "posted", "api": "CGEventPostToPid", "pid": pid,
                    "keycode": key, "flags": flags.rawValue,
                    "events": ["keyDown", "keyUp"], "delivery_acknowledged": false])
        }
        if closing {
            try post(CGKeyCode(kVK_ANSI_Q), flags: .maskCommand)
            return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
        }
        try require(windows.count == 1, "Expected exactly one on-screen normal target window")
        let window = windows[0]
        record(["phase": "target", "pid": pid, "binary": binary.path,
                "window_id": window.windowID, "title": window.title ?? "",
                "width": window.frame.width, "height": window.frame.height])
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false

        func screenshot(_ name: String) async throws {
            try focused()
            let current = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try require(current.windows.contains { $0.windowID == window.windowID && $0.isOnScreen &&
                $0.owningApplication?.processID == pid }, "Target window disappeared")
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try focused()
            let destination = output.appendingPathComponent(name)
            guard let writer = CGImageDestinationCreateWithURL(destination as CFURL,
                UTType.png.identifier as CFString, 1, nil) else {
                throw Failure(message: "Cannot create PNG destination")
            }
            CGImageDestinationAddImage(writer, image, nil)
            try require(CGImageDestinationFinalize(writer), "Cannot write PNG")
            record(["phase": "capture", "file": destination.path,
                    "width": image.width, "height": image.height])
        }
        try await screenshot("initial.png")
        try post(CGKeyCode(kVK_DownArrow), flags: [])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        advanceMainLoop()
        try await screenshot("down.png")
        record(["status": "CAPTURED_PENDING_VISUAL_REVIEW"])
    }
}
