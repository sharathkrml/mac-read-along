import AppKit

/// The floating session widget: state, live waveform, the microphone, the last
/// words heard, and stop. Draggable, non-activating, restorable from the menu
/// bar.
@MainActor
final class StatusCard {
    private var panel: StatusPanel?
    private let waveform = WaveformView(barCount: 32)
    private let stateMicro = Widget.microLabel("PAUSED")
    private let bigLabel = Widget.displayLabel("Paused", size: 24, weight: .light, color: ReaderTheme.textSecondary)
    private let snippet = NSTextField(labelWithString: "")
    private let stopButton = PillButton("Stop", kind: .primary)
    private let retryButton = PillButton("Retry", kind: .secondary)
    private let micPicker = NSPopUpButton()
    private var isListening = false

    var onStop: (() -> Void)? {
        didSet { stopButton.onPress = onStop }
    }
    var onRetry: (() -> Void)? {
        didSet { retryButton.onPress = onRetry }
    }
    var onMicrophoneChange: (() -> Void)?

    var isShown: Bool { panel?.isVisible ?? false }

    private static let cardWidth: CGFloat = 340
    private static let cardHeight: CGFloat = 136

    func show(near frame: CGRect) {
        if panel == nil {
            makePanel()
        }
        guard let panel else { return }
        refreshMicrophone()

        let width = Self.cardWidth
        let height = Self.cardHeight
        let x = max(frame.minX + 16, frame.maxX - width - 24)
        let y = max(frame.minY + 16, frame.maxY - height - 36)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        let firstShow = !panel.isVisible
        panel.orderFrontRegardless()
        if firstShow {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The card mirrors engine state; failures offer retry, idle means paused.
    func update(state: SpeechEngineState) {
        isListening = false
        switch state {
        case .idle:
            waveform.reset()
            stateMicro.attributedStringValue = ReaderTheme.micro("PAUSED", color: ReaderTheme.textSecondary)
            bigLabel.stringValue = "Paused"
            bigLabel.textColor = ReaderTheme.textSecondary
            setSnippet("", color: ReaderTheme.textTertiary)
            retryButton.isHidden = true
        case .starting(let message):
            waveform.reset()
            stateMicro.attributedStringValue = ReaderTheme.micro("STARTING", color: ReaderTheme.amber)
            bigLabel.stringValue = "Starting"
            bigLabel.textColor = ReaderTheme.textPrimary
            setSnippet(message, color: ReaderTheme.textSecondary)
            retryButton.isHidden = true
        case .listening:
            isListening = true
            stateMicro.attributedStringValue = ReaderTheme.micro("FOLLOWING", color: ReaderTheme.amber)
            bigLabel.stringValue = "Listening"
            bigLabel.textColor = ReaderTheme.textPrimary
            setSnippet("Say a few words…", color: ReaderTheme.textTertiary)
            retryButton.isHidden = true
        case .failed(let message):
            waveform.reset()
            stateMicro.attributedStringValue = ReaderTheme.micro("ATTENTION", color: ReaderTheme.danger)
            bigLabel.stringValue = "Engine error"
            bigLabel.textColor = ReaderTheme.danger
            setSnippet(message, color: ReaderTheme.danger)
            retryButton.isHidden = false
        }
    }

    /// The last words the engine heard, so the reader can see it is following.
    func updateTranscript(_ text: String, isFinal: Bool) {
        guard isListening, !text.isEmpty else { return }
        setSnippet(text, color: isFinal ? ReaderTheme.textPrimary : ReaderTheme.textSecondary)
    }

    func addLevel(_ level: Float) {
        guard isListening else { return }
        waveform.add(level)
    }

    private func setSnippet(_ text: String, color: NSColor) {
        snippet.stringValue = text
        snippet.textColor = color
        snippet.toolTip = text.isEmpty ? nil : text
    }

    private func refreshMicrophone() {
        let preferredID = AppSettings.standard.microphoneID
        micPicker.setMicrophoneChoices(preferredID: preferredID)
        let name = MicrophoneCatalog.resolve(preferredID: preferredID)?.localizedName
        micPicker.toolTip = "Microphone: \(name ?? "none")"
    }

    @objc private func microphoneChanged() {
        AppSettings.standard.microphoneID = micPicker.selectedItem?.representedObject as? String ?? ""
        refreshMicrophone()
        onMicrophoneChange?()
    }

    private func makePanel() {
        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let view = Widget.card(radius: 26)
        view.layer?.shadowOpacity = 0.45
        view.layer?.shadowRadius = 26
        view.layer?.shadowOffset = CGSize(width: 0, height: -10)

        snippet.translatesAutoresizingMaskIntoConstraints = false
        snippet.font = ReaderTheme.interfaceFont(size: 12)
        snippet.textColor = ReaderTheme.textTertiary
        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 1
        // The card is a fixed-width HUD; long transcript text truncates
        // instead of pushing the window wider.
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        micPicker.translatesAutoresizingMaskIntoConstraints = false
        micPicker.controlSize = .regular
        micPicker.font = ReaderTheme.interfaceFont(size: 11)
        micPicker.target = self
        micPicker.action = #selector(microphoneChanged)
        refreshMicrophone()

        for subview in [waveform, stateMicro, bigLabel, snippet, stopButton, retryButton, micPicker] {
            view.addSubview(subview)
        }
        retryButton.isHidden = true

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            waveform.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            waveform.widthAnchor.constraint(equalToConstant: 96),
            waveform.heightAnchor.constraint(equalToConstant: 22),

            stateMicro.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: 10),
            stateMicro.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),

            stopButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stopButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stopButton.widthAnchor.constraint(equalToConstant: 64),
            stopButton.heightAnchor.constraint(equalToConstant: 28),

            retryButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 58),
            retryButton.heightAnchor.constraint(equalToConstant: 28),

            bigLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            bigLabel.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 4),
            bigLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            snippet.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            snippet.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            snippet.topAnchor.constraint(greaterThanOrEqualTo: bigLabel.bottomAnchor, constant: 2),
            snippet.bottomAnchor.constraint(equalTo: micPicker.topAnchor, constant: -8),

            micPicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            micPicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            micPicker.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        panel.contentView = view
        self.panel = panel
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
