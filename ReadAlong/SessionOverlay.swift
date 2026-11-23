import AppKit

/// A click-through outline around the picked window while a session is active.
@MainActor
final class SessionOverlay {
    private var windows: [OverlayWindow] = []
    private var target: WindowInfo?
    private var onTargetLost: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var isActive = false
    private var hiddenForOffScreen = false

    func begin(window: WindowInfo, onTargetLost: @escaping () -> Void) {
        guard !isActive else { return }
        Log.note("overlay begin for window \(window.windowID) \(window.ownerName)")
        isActive = true
        target = window
        self.onTargetLost = onTargetLost

        for screen in NSScreen.screens {
            let overlay = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.ignoresMouseEvents = true
            overlay.level = .floating
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            overlay.hasShadow = false

            let view = OverlayView()
            view.screenFrame = screen.frame
            view.targetFrame = window.frame
            overlay.contentView = view
            overlay.setFrame(screen.frame, display: false)
            overlay.orderFrontRegardless()
            windows.append(overlay)
        }

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        target = nil
        onTargetLost = nil
        hiddenForOffScreen = false
    }

    private func refresh() {
        guard isActive, let target else { return }

        guard let current = WindowInfo.current(windowID: target.windowID) else {
            Log.note("target window \(target.windowID) lost")
            let handler = onTargetLost
            end()
            handler?()
            return
        }

        if !WindowInfo.isOnScreen(windowID: target.windowID) {
            if !hiddenForOffScreen {
                windows.forEach { $0.orderOut(nil) }
                hiddenForOffScreen = true
            }
            return
        }

        if hiddenForOffScreen {
            windows.forEach { $0.orderFrontRegardless() }
            hiddenForOffScreen = false
        }

        self.target = current
        for window in windows {
            (window.contentView as? OverlayView)?.targetFrame = current.frame
            window.contentView?.needsDisplay = true
        }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    var screenFrame: CGRect = .zero
    var targetFrame: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return }

        let local = targetFrame.offsetBy(
            dx: -screenFrame.origin.x,
            dy: -screenFrame.origin.y
        )
        let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
        NSColor.systemOrange.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
