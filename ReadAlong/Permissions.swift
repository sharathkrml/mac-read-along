import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// Where every permission check and fix lives, so all surfaces deep-link to
/// the same place.
enum Permissions {
    @MainActor
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @MainActor
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    static func openMicrophonePane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openScreenRecordingPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Returns true when screen recording is granted; otherwise requests it and
    /// explains the System Settings path. Screen reading cannot work without it.
    @MainActor
    static func ensureScreenRecording() -> Bool {
        Log.note("screen recording preflight: \(screenRecordingGranted())")
        if screenRecordingGranted() { return true }

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
            openScreenRecordingPane()
        }
        return false
    }
}
