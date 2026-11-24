import AppKit

// MARK: - Building blocks

@MainActor
enum Widget {
    static func card(radius: CGFloat = 28, fill: NSColor = ReaderTheme.card) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = ReaderTheme.hairline.cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.30
        view.layer?.shadowRadius = 22
        view.layer?.shadowOffset = CGSize(width: 0, height: -8)
        return view
    }

    static func microLabel(_ text: String, color: NSColor = ReaderTheme.textSecondary, size: CGFloat = 10) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: ReaderTheme.micro(text, color: color, size: size))
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func titleLabel(
        _ text: String,
        size: CGFloat = 20,
        weight: NSFont.Weight = .semibold,
        color: NSColor = ReaderTheme.textPrimary
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReaderTheme.interfaceFont(size: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func displayLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .thin,
        color: NSColor = ReaderTheme.textPrimary
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReaderTheme.display(size: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func bodyLabel(
        _ text: String,
        size: CGFloat = 12,
        color: NSColor = ReaderTheme.textSecondary
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReaderTheme.interfaceFont(size: size)
        label.textColor = color
        return label
    }

    static func iconTile(
        symbol: String,
        tint: NSColor = ReaderTheme.amber,
        size: CGFloat = 44
    ) -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        tile.layer?.cornerRadius = 12
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = tint.withAlphaComponent(0.18).cgColor

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.contentTintColor = tint
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
        tile.addSubview(image)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    static func capsuleLabel(_ text: String, tint: NSColor = ReaderTheme.textSecondary, size: CGFloat = 9) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = ReaderTheme.inset.cgColor
        pill.layer?.cornerRadius = 10
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = ReaderTheme.hairline.cgColor

        let label = NSTextField(labelWithAttributedString: ReaderTheme.micro(text, color: tint, size: size))
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    static func divider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = ReaderTheme.hairline.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

// MARK: - Backdrop

/// Graphite gradient with a faint amber glow in the upper right, used by the
/// reader and the setup window.
final class BackdropView: NSView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ReaderTheme.canvas.cgColor

        gradient.colors = [ReaderTheme.canvasTop.cgColor, ReaderTheme.canvasBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)

        glow.type = .radial
        glow.colors = [
            ReaderTheme.amber.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.85, y: 0.92)
        glow.endPoint = CGPoint(x: 0.35, y: 0.35)
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) {
        fatalError("BackdropView is built in code")
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        glow.frame = bounds
    }
}

// MARK: - Buttons

@MainActor
final class PillButton: NSButton {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    var onPress: (() -> Void)?
    private let kind: Kind
    private var trackingAreaRef: NSTrackingArea?
    private var hovering = false

    init(_ title: String, kind: Kind = .primary) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        font = ReaderTheme.interfaceFont(size: 13, weight: .semibold)
        target = self
        action = #selector(pressed)
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("PillButton is built in code")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(12, bounds.height / 2)
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        apply()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        apply()
    }

    @objc private func pressed() {
        onPress?()
    }

    private func apply() {
        switch kind {
        case .primary:
            layer?.backgroundColor = (hovering ? ReaderTheme.amberSoft : ReaderTheme.amber).cgColor
            layer?.borderWidth = 0
            contentTintColor = ReaderTheme.inkOnAmber
        case .secondary:
            layer?.backgroundColor = (hovering ? ReaderTheme.inset : ReaderTheme.cardRaised).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ReaderTheme.hairline.cgColor
            contentTintColor = ReaderTheme.textPrimary
        case .quiet:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            contentTintColor = ReaderTheme.textSecondary
        }
        updateAppearance()
    }

    private func updateAppearance() {
        alphaValue = isEnabled ? 1 : 0.4
    }
}

// MARK: - Progress

final class ProgressBar: NSView {
    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var fillColor = ReaderTheme.amber

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("ProgressBar is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        ReaderTheme.inset.setFill()
        track.fill()

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }
        let fillRect = CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * clamped), height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        fill.fill()
    }
}

// MARK: - Activity bars

/// Small five-bar equalizer used as a listening indicator, echoing the music
/// widget in the reference. It is an activity animation, not a data readout.
@MainActor
final class ActivityBars: NSView {
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updateTimer()
            needsDisplay = true
        }
    }

    var tint: NSColor = ReaderTheme.amber {
        didSet { needsDisplay = true }
    }

    private var timer: Timer?
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityBars is built in code")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 20) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopTimer()
        } else {
            updateTimer()
        }
    }

    private func updateTimer() {
        guard isActive, window != nil else {
            stopTimer()
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(timeInterval: 0.12, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        phase += 0.42
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = 5
        let gap: CGFloat = 3
        let barWidth = max(2, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let factors: [CGFloat] = [0.5, 0.9, 0.62, 1.0, 0.42]

        for index in 0..<count {
            let wave: CGFloat
            if isActive {
                wave = 0.32 + 0.68 * abs(sin(phase + CGFloat(index) * 0.85))
            } else {
                wave = 0.16
            }
            let height = max(3, bounds.height * wave * factors[index])
            let rect = CGRect(
                x: CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            tint.withAlphaComponent(isActive ? 1 : 0.35).setFill()
            path.fill()
        }
    }
}

// MARK: - Waveform

/// Scrolling symmetric bars driven by live mic levels; flat while silent or
/// stopped. Used by the launcher mic test and the session status card.
@MainActor
final class WaveformView: NSView {
    private var levels: [CGFloat]

    init(barCount: Int = 76) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("WaveformView is built in code")
    }

    func add(_ level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(min(max(level, 0), 1)))
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = levels.count
        let gap: CGFloat = bounds.width < 160 ? 1 : 2
        let barWidth = max(1, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        for (index, level) in levels.enumerated() {
            let height = max(2, bounds.height * level)
            let rect = CGRect(
                x: CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            ReaderTheme.amber.withAlphaComponent(0.16 + 0.74 * level).setFill()
            path.fill()
        }
    }
}

// MARK: - Microphone picker

extension NSPopUpButton {
    /// Rows shared by the microphone pickers in the setup window and the status card.
    /// A saved device that is gone stays listed so it can be reselected.
    func setMicrophoneChoices(preferredID: String) {
        let choices = MicrophoneCatalog.choices(preferredID: preferredID)
        // Rebuild only when the device list itself changed; state updates
        // refresh the selection without resetting an open menu.
        if itemArray.map(\.title) != choices.map(\.title) {
            removeAllItems()
            let mic = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone")
            for choice in choices {
                addItem(withTitle: choice.title)
                lastItem?.representedObject = choice.id
                lastItem?.image = mic
            }
        }
        selectItem(at: itemArray.firstIndex {
            ($0.representedObject as? String) == preferredID
        } ?? 0)
    }
}

// MARK: - Window placement

extension NSWindow {
    /// The reading surfaces open on the primary display. A window restored
    /// onto a disconnected or sleeping display is invisible; bring it home.
    /// (Secondary-display placement can be restored once there is a reason.)
    func ensureOnVisibleScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        guard !visible.intersects(frame) else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}

// MARK: - Keycaps

@MainActor
final class KeycapsView: NSView {
    private let stack = NSStackView()

    init(keys: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setKeys(keys)
    }

    required init?(coder: NSCoder) {
        fatalError("KeycapsView is built in code")
    }

    func setKeys(_ text: String) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let characters = text.isEmpty ? ["—"] : text.map(String.init)
        for character in characters {
            stack.addArrangedSubview(cap(character))
        }
    }

    private func cap(_ symbol: String) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = ReaderTheme.inset.cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = ReaderTheme.hairline.cgColor

        let label = NSTextField(labelWithString: symbol)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReaderTheme.interfaceFont(size: 14, weight: .medium)
        label.textColor = ReaderTheme.textPrimary
        label.alignment = .center
        view.addSubview(label)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 30),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6),
        ])
        return view
    }
}
