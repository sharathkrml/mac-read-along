import AppKit
import CoreGraphics

@MainActor
final class SessionController {
    enum State: Equatable {
        case idle
        case picking
        case active(CGWindowID)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?() }
    }

    var onStateChange: (() -> Void)?

    private let picker = WindowPicker()
    private let overlay = SessionOverlay()

    func toggle() {
        Log.note("toggle; state: \(String(describing: self.state))")
        switch state {
        case .idle:
            beginPicking()
        case .picking:
            cancelPicking()
        case .active:
            end()
        }
    }

    func end() {
        picker.end()
        overlay.end()
        state = .idle
    }

    private func beginPicking() {
        guard ScreenRecordingPermission.ensure() else {
            Log.note("screen recording not granted; staying idle")
            return
        }
        Log.note("screen recording granted; beginning pick")
        state = .picking
        picker.begin(
            onPick: { [weak self] info in self?.attach(to: info) },
            onCancel: { [weak self] in self?.state = .idle }
        )
    }

    private func cancelPicking() {
        picker.end()
        state = .idle
    }

    private func attach(to info: WindowInfo) {
        Log.note("attached to window \(info.windowID) \(info.ownerName)")
        picker.end()
        state = .active(info.windowID)
        overlay.begin(window: info) { [weak self] in
            self?.end()
        }
    }
}
