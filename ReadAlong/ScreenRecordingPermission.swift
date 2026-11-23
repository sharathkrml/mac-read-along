import AppKit

enum ScreenRecordingPermission {
    /// Returns true when screen recording is granted; otherwise requests it and
    /// explains the System Settings path. Screen reading cannot work without it.
    @MainActor
    static func ensure() -> Bool {
        let preflight = CGPreflightScreenCaptureAccess()
        Log.note("screen recording preflight: \(preflight)")
        if preflight { return true }

        let requested = CGRequestScreenCaptureAccess()
        Log.note("screen recording request result: \(requested)")
        if requested { return true }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is required"
        alert.informativeText = """
        Read Along needs to see the text on screen to follow your reading.

        Open System Settings → Privacy & Security → Screen Recording, enable Read Along, then quit and reopen the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }
}
