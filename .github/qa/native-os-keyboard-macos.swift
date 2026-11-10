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
        try require(CommandLine.arguments.count == 4, "Usage: native-key PID BINARY OUTPUT_DIRECTORY")
        guard let pid = pid_t(CommandLine.arguments[1]),
              let app = NSRunningApplication(processIdentifier: pid) else {
            throw Failure(message: "Target application unavailable")
        }
        let binary = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try require(app.executableURL?.resolvingSymlinksInPath() == binary,
                    "PID executable mismatch")
        try require(app.activate(options: []), "Application activation refused")
        try await Task.sleep(nanoseconds: 1_000_000_000)

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
        try focused()
        try require(CGPreflightPostEventAccess(), "Posting permission changed")
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: false) else {
            throw Failure(message: "Cannot construct Down key pair")
        }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.postToPid(pid)
        up.postToPid(pid)
        record(["phase": "posted", "api": "CGEventPostToPid", "pid": pid,
                "keycode": kVK_DownArrow, "events": ["keyDown", "keyUp"],
                "delivery_acknowledged": false])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await screenshot("down.png")
        record(["status": "CAPTURED_PENDING_VISUAL_REVIEW"])
    }
}
