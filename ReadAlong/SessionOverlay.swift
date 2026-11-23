import AppKit

/// Highlight rectangles for one tracker state, normalized to the reading
/// surface's frame with the origin at its bottom-left corner.
struct HighlightRects: Equatable {
    var current: [CGRect] = []
    var next: [CGRect] = []
}

/// A click-through overlay over the picked window while a session is active:
/// the window outline plus the two-stage sentence highlight (ADR-0001).
@MainActor
final class SessionOverlay {
    private var windows: [OverlayWindow] = []
    private var target: WindowInfo?
    private var onTargetLost: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var isActive = false
    private var hiddenForOffScreen = false

    private(set) var highlights: HighlightRects?
    private(set) var notice: String?

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
        highlights = nil
        notice = nil
    }

    func setHighlights(_ rects: HighlightRects?) {
        guard highlights != rects else { return }
        highlights = rects
        redraw()
    }

    func setNotice(_ text: String?) {
        guard notice != text else { return }
        notice = text
        redraw()
    }

    private func redraw() {
        for window in windows {
            (window.contentView as? OverlayView)?.highlights = highlights
            (window.contentView as? OverlayView)?.notice = notice
            window.contentView?.needsDisplay = true
        }
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
        }
        redraw()
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    var screenFrame: CGRect = .zero
    var targetFrame: CGRect = .zero
    var highlights: HighlightRects?
    var notice: String?

    override func draw(_ dirtyRect: NSRect) {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return }

        let local = targetFrame.offsetBy(
            dx: -screenFrame.origin.x,
            dy: -screenFrame.origin.y
        )

        if let highlights {
            drawHighlights(highlights, in: local)
        }

        let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
        NSColor.systemOrange.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()

        if let notice, !notice.isEmpty {
            drawNotice(notice, in: local)
        }
    }

    /// Highlight rectangles arrive normalized to the target window (origin at
    /// its bottom-left, Vision's convention); scale them into screen space.
    private func drawHighlights(_ highlights: HighlightRects, in window: CGRect) {
        for rect in highlights.next {
            drawHighlight(
                rect: scaled(rect, to: window).offsetBy(
                    dx: -screenFrame.origin.x,
                    dy: -screenFrame.origin.y
                ),
                fill: NSColor.white.withAlphaComponent(0.14),
                stroke: nil
            )
        }
        for rect in highlights.current {
            drawHighlight(
                rect: scaled(rect, to: window).offsetBy(
                    dx: -screenFrame.origin.x,
                    dy: -screenFrame.origin.y
                ),
                fill: ReaderTheme.readingStroke.withAlphaComponent(0.32),
                stroke: ReaderTheme.readingStroke.withAlphaComponent(0.95)
            )
        }
    }

    private func drawHighlight(rect: CGRect, fill: NSColor, stroke: NSColor?) {
        let radius = min(4, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func scaled(_ rect: CGRect, to window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + rect.minX * window.width,
            y: window.minY + rect.minY * window.height,
            width: rect.width * window.width,
            height: rect.height * window.height
        )
    }

    private func drawNotice(_ text: String, in window: CGRect) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ReaderTheme.interfaceFont(size: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = string.size(withAttributes: attributes)
        let chip = CGRect(
            x: window.midX - size.width / 2 - 14,
            y: window.maxY - size.height - 26,
            width: size.width + 28,
            height: size.height + 12
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        string.draw(at: CGPoint(x: chip.minX + 14, y: chip.minY + 6), withAttributes: attributes)
    }
}
