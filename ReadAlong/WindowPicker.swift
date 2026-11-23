import AppKit

/// Dims the screens, outlines every on-screen window, and attaches to the one
/// clicked. Hover follows the pointer without needing Accessibility.
@MainActor
final class WindowPicker {
    private var pickerWindows: [PickerWindow] = []
    private var candidates: [WindowInfo] = []
    private var hovered: WindowInfo?
    private var onPick: ((WindowInfo) -> Void)?
    private var onCancel: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var isActive = false

    func begin(onPick: @escaping (WindowInfo) -> Void, onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onPick = onPick
        self.onCancel = onCancel
        candidates = WindowInfo.onScreenWindows()
        Log.note("picker begin: \(self.candidates.count) windows on \(NSScreen.screens.count) screens")

        NSApp.activate()
        NSCursor.crosshair.push()

        for screen in NSScreen.screens {
            let window = PickerWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true

            let view = PickerView()
            view.coordinator = self
            view.screenFrame = screen.frame
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            pickerWindows.append(window)
        }
        pickerWindows.first?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateHover()
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func end() {
        finish()
    }

    func window(at point: CGPoint) -> WindowInfo? {
        candidates.first { $0.frame.contains(point) }
    }

    func allCandidates() -> [WindowInfo] { candidates }
    func hoveredWindow() -> WindowInfo? { hovered }

    func pick(at globalPoint: CGPoint) {
        guard let info = window(at: globalPoint) else {
            Log.note("pick at \(globalPoint.x),\(globalPoint.y): no window")
            return
        }
        Log.note("picked window \(info.windowID) \(info.ownerName)")
        let handler = onPick
        finish()
        handler?(info)
    }

    private func cancel() {
        let handler = onCancel
        finish()
        handler?()
    }

    private func updateHover() {
        guard isActive else { return }
        let point = NSEvent.mouseLocation
        let newHover = window(at: point)
        guard newHover != hovered else { return }
        hovered = newHover
        for window in pickerWindows {
            window.contentView?.needsDisplay = true
        }
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        pickerWindows.forEach { $0.orderOut(nil) }
        pickerWindows.removeAll()
        candidates.removeAll()
        hovered = nil
        NSCursor.pop()
        onPick = nil
        onCancel = nil
    }
}

final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerView: NSView {
    weak var coordinator: WindowPicker?
    var screenFrame: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.52).setFill()
        bounds.fill()

        guard let coordinator else { return }
        let hovered = coordinator.hoveredWindow()

        for info in coordinator.allCandidates() {
            let local = info.frame.offsetBy(
                dx: -screenFrame.origin.x,
                dy: -screenFrame.origin.y
            )
            let path = NSBezierPath(roundedRect: local, xRadius: 14, yRadius: 14)
            if info == hovered {
                ReaderTheme.amber.withAlphaComponent(0.10).setFill()
                path.fill()
                ReaderTheme.amber.setStroke()
                path.lineWidth = 2.5
                path.stroke()
                drawLabel(for: info, at: local)
            } else {
                NSColor.white.withAlphaComponent(0.22).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        drawHint()
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.pick(at: NSEvent.mouseLocation)
    }

    private func drawLabel(for info: WindowInfo, at rect: CGRect) {
        let name = info.ownerName as NSString
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: ReaderTheme.interfaceFont(size: 13, weight: .semibold),
            .foregroundColor: ReaderTheme.textPrimary,
        ]
        let nameSize = name.size(withAttributes: nameAttributes)
        let micro = ReaderTheme.micro("WINDOW", color: ReaderTheme.amber, size: 9)
        let microSize = micro.size()

        let cardWidth = max(nameSize.width, microSize.width) + 26
        let cardHeight: CGFloat = 46
        let cardRect = CGRect(
            x: rect.minX + 12,
            y: rect.maxY - cardHeight - 12,
            width: cardWidth,
            height: cardHeight
        )
        ReaderTheme.card.withAlphaComponent(0.96).setFill()
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)
        card.fill()
        ReaderTheme.hairline.setStroke()
        card.lineWidth = 1
        card.stroke()

        micro.draw(at: CGPoint(x: cardRect.minX + 13, y: cardRect.maxY - 22))
        name.draw(
            at: CGPoint(x: cardRect.minX + 13, y: cardRect.minY + 8),
            withAttributes: nameAttributes
        )
    }

    private func drawHint() {
        let micro = ReaderTheme.micro("CHOOSE A WINDOW", color: ReaderTheme.amber, size: 9)
        let action = "Click to start  ·  Esc to cancel" as NSString
        let actionAttributes: [NSAttributedString.Key: Any] = [
            .font: ReaderTheme.interfaceFont(size: 12, weight: .medium),
            .foregroundColor: ReaderTheme.textPrimary,
        ]
        let actionSize = action.size(withAttributes: actionAttributes)
        let microSize = micro.size()

        let width = max(actionSize.width, microSize.width) + 34
        let rect = CGRect(
            x: bounds.midX - width / 2,
            y: 40,
            width: width,
            height: 56
        )
        ReaderTheme.card.withAlphaComponent(0.94).setFill()
        let card = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        card.fill()
        ReaderTheme.hairline.setStroke()
        card.lineWidth = 1
        card.stroke()

        ReaderTheme.amber.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: rect.minX + 15, y: rect.midY - 2.5, width: 5, height: 5)).fill()
        micro.draw(at: CGPoint(x: rect.minX + 28, y: rect.maxY - 24))
        action.draw(
            at: CGPoint(x: rect.minX + 28, y: rect.minY + 10),
            withAttributes: actionAttributes
        )
    }
}
