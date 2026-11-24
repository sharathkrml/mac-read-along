import AppKit

/// Highlight rectangles for one tracker state, normalized to the reading
/// surface's frame with the origin at its bottom-left corner.
struct HighlightRects: Equatable {
    var current: [CGRect] = []
    var next: [CGRect] = []
    /// The exact word under the voice; drawn with dots below the group rule.
    var word: [CGRect] = []
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
    private(set) var tone: SurfaceTone = .dark

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

    /// The captured window's brightness changed; repaint with the matching
    /// highlight palette.
    func setTone(_ tone: SurfaceTone) {
        guard tone != self.tone else { return }
        self.tone = tone
        redraw()
    }

    private func redraw() {
        for window in windows {
            guard let view = window.contentView as? OverlayView else { continue }
            view.highlights = highlights
            view.notice = notice
            view.tone = tone
            view.needsDisplay = true
        }
    }

    private func refresh() {
        guard isActive, let target else { return }

        // One window-list query covers both moving and hiding: the target is
        // in the on-screen list exactly when its window is visible. Repaint
        // only when it moved, so a still window costs no redraws at all.
        if let current = WindowInfo.onScreenWindows().first(where: { $0.windowID == target.windowID }) {
            if hiddenForOffScreen {
                windows.forEach { $0.orderFrontRegardless() }
                hiddenForOffScreen = false
            }
            guard current.frame != target.frame else { return }
            self.target = current
            for window in windows {
                (window.contentView as? OverlayView)?.targetFrame = current.frame
            }
            redraw()
            return
        }

        guard WindowInfo.current(windowID: target.windowID) != nil else {
            Log.note("target window \(target.windowID) lost")
            let handler = onTargetLost
            end()
            handler?()
            return
        }

        if !hiddenForOffScreen {
            windows.forEach { $0.orderOut(nil) }
            hiddenForOffScreen = true
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
    var highlights: HighlightRects?
    var notice: String?
    var tone: SurfaceTone = .dark

    override func draw(_ dirtyRect: NSRect) {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return }

        let local = targetFrame.offsetBy(
            dx: -screenFrame.origin.x,
            dy: -screenFrame.origin.y
        )

        if let highlights {
            drawHighlights(highlights, in: local)
        }

        // No full-window wash: tinting a light PDF crushes the text contrast.
        let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
        NSColor.systemOrange.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        if let notice, !notice.isEmpty {
            drawNotice(notice, in: local)
        }
    }

    /// Highlight rectangles arrive normalized to the target window (origin at
    /// its bottom-left, Vision's convention); scale them into screen space.
    private func drawHighlights(_ highlights: HighlightRects, in window: CGRect) {
        let palette = HighlightPalette(tone: tone)
        let next = highlights.next.map { place($0, in: window) }
        let current = highlights.current.map { place($0, in: window) }
        for rect in next {
            drawHighlight(rect: rect, fill: palette.nextFill, underline: palette.nextUnderline)
        }
        for rect in current {
            drawHighlight(rect: rect, fill: palette.currentFill, underline: palette.currentUnderline)
        }
        for rect in highlights.word.map({ place($0, in: window) }) {
            let band = current.first { $0.intersects(rect) } ?? rect
            drawWordMarker(rect: rect, band: band, palette: palette)
        }
    }

    /// Normalized (window-local) rectangles scale into the view's local
    /// target rect. The rect is already offset onto this screen when `draw`
    /// computes it, so no screen origin is applied again.
    func place(_ rect: CGRect, in window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + rect.minX * window.width,
            y: window.minY + rect.minY * window.height,
            width: rect.width * window.width,
            height: rect.height * window.height
        )
    }

    /// A low-alpha wash plus a bottom rule: the sentence reads as highlighted
    /// while every glyph keeps its own contrast, on white paper or dark UI.
    private func drawHighlight(rect: CGRect, fill: NSColor, underline: NSColor) {
        let radius = min(4, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()

        let thickness = min(2.5, max(1.5, rect.height * 0.08))
        let rule = CGRect(
            x: rect.minX - 1,
            y: rect.minY - 1,
            width: rect.width + 2,
            height: thickness
        )
        underline.setFill()
        NSBezierPath(roundedRect: rule, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    /// The exact word gets a deeper wash and a dotted rule below the group's
    /// solid rule: precise enough to follow the voice, quiet enough to leave
    /// the glyphs alone.
    private func drawWordMarker(rect: CGRect, band: CGRect, palette: HighlightPalette) {
        let radius = min(4, rect.height / 2)
        palette.wordFill.setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: -1, dy: -1),
            xRadius: radius,
            yRadius: radius
        ).fill()

        let thickness = max(1.5, min(3, rect.height * 0.12))
        let y = band.minY - thickness - 3
        let dots = NSBezierPath()
        dots.move(to: CGPoint(x: rect.minX + thickness / 2, y: y))
        dots.line(to: CGPoint(x: rect.maxX - thickness / 2, y: y))
        dots.lineWidth = thickness
        dots.lineCapStyle = .round
        dots.setLineDash([0.5, thickness * 2], count: 2, phase: 0)
        palette.wordDots.setStroke()
        dots.stroke()
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

/// Highlight colors chosen for the captured surface's brightness. Light pages
/// get a whisper of amber so black text survives; dark surfaces can take more.
private struct HighlightPalette {
    let currentFill: NSColor
    let currentUnderline: NSColor
    let nextFill: NSColor
    let nextUnderline: NSColor
    let wordFill: NSColor
    let wordDots: NSColor

    init(tone: SurfaceTone) {
        switch tone {
        case .light:
            currentFill = ReaderTheme.amber.withAlphaComponent(0.15)
            currentUnderline = ReaderTheme.amber.withAlphaComponent(0.95)
            nextFill = ReaderTheme.amber.withAlphaComponent(0.05)
            nextUnderline = ReaderTheme.amber.withAlphaComponent(0.35)
            wordFill = ReaderTheme.amber.withAlphaComponent(0.12)
            wordDots = ReaderTheme.amberDeep
        case .dark:
            currentFill = ReaderTheme.amber.withAlphaComponent(0.22)
            currentUnderline = ReaderTheme.amber.withAlphaComponent(0.90)
            nextFill = NSColor.white.withAlphaComponent(0.06)
            nextUnderline = NSColor.white.withAlphaComponent(0.28)
            wordFill = ReaderTheme.amber.withAlphaComponent(0.12)
            wordDots = ReaderTheme.amberSoft
        }
    }
}
