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
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()

        guard let coordinator else { return }
        let hovered = coordinator.hoveredWindow()

        for info in coordinator.allCandidates() {
            let local = info.frame.offsetBy(
                dx: -screenFrame.origin.x,
                dy: -screenFrame.origin.y
            )
            let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
            if info == hovered {
                NSColor.systemOrange.withAlphaComponent(0.12).setFill()
                path.fill()
                NSColor.systemOrange.setStroke()
                path.lineWidth = 3
                path.stroke()
                drawLabel(for: info, at: local)
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
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
        let text = info.ownerName as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: rect.minX + 10,
            y: rect.maxY - textSize.height - 22,
            width: textSize.width + 20,
            height: textSize.height + 10
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 7, yRadius: 7).fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + 10, y: labelRect.minY + 5),
            withAttributes: attributes
        )
    }

    private func drawHint() {
        let text = "Click a window to read  ·  Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let textSize = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - textSize.width / 2 - 14,
            y: 36,
            width: textSize.width + 28,
            height: textSize.height + 12
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        text.draw(
            at: CGPoint(x: rect.minX + 14, y: rect.minY + 6),
            withAttributes: attributes
        )
    }
}
