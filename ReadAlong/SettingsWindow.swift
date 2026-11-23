import AppKit

/// The Settings window: model name, start hotkey, status-card visibility.
/// All values persist; changing the model restarts a running engine.
@MainActor
final class SettingsController: NSObject, NSTextFieldDelegate {
    var onModelChange: (() -> Void)?
    var onHotkeyChange: ((UInt32, UInt32) -> Void)?
    var onCardVisibilityChange: (() -> Void)?
    var onMicrophoneChange: (() -> Void)?

    private var window: NSWindow?
    private var modelField: NSTextField?
    private var cardSwitch: PillSwitch?
    private var hotkeyRecorder: HotkeyRecorderView?
    private var micPicker: NSPopUpButton?
    private var micHint: NSTextField?

    func show() {
        if window == nil {
            window = makeWindow()
        }
        refresh()
        window?.ensureOnVisibleScreen()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window?.makeFirstResponder(nil)
    }

    private func refresh() {
        modelField?.stringValue = AppSettings.standard.model
        hotkeyRecorder?.setKeys(HotkeyManager.displayString(
            keyCode: AppSettings.standard.hotkeyCode,
            modifiers: AppSettings.standard.hotkeyModifiers
        ))
        hotkeyRecorder?.isRecording = false
        cardSwitch?.isOn = AppSettings.standard.cardVisible
        refreshMicrophone()
    }

    /// Rebuilt on each show: devices plugged in or removed while the window
    /// was closed must appear (or select the system default).
    private func refreshMicrophone() {
        guard let micPicker else { return }
        micPicker.setMicrophoneChoices(preferredID: AppSettings.standard.microphoneID)
        updateMicrophoneHint()
    }

    /// Names the device capture actually resolves to, so "System default" is
    /// never a mystery.
    private func updateMicrophoneHint() {
        let name = MicrophoneCatalog.resolve(preferredID: AppSettings.standard.microphoneID)?.localizedName
        micHint?.attributedStringValue = ReaderTheme.micro(
            name.map { "USING · \($0)" } ?? "NO INPUT DEVICE FOUND",
            color: name == nil ? ReaderTheme.danger : ReaderTheme.textSecondary,
            size: 9
        )
        micHint?.toolTip = name
    }

    // MARK: - Changes

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field == modelField else { return }
        commitModel()
    }

    private func commitModel() {
        guard let modelField else { return }
        let name = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != AppSettings.standard.model else { return }
        AppSettings.standard.model = name
        onModelChange?()
    }

    private func toggleCard(_ isOn: Bool) {
        AppSettings.standard.cardVisible = isOn
        onCardVisibilityChange?()
    }

    @objc private func microphoneChanged() {
        AppSettings.standard.microphoneID = micPicker?.selectedItem?.representedObject as? String ?? ""
        updateMicrophoneHint()
        onMicrophoneChange?()
    }

    private func recordHotkey(keyCode: UInt32, carbonModifiers: UInt32) {
        AppSettings.standard.hotkeyCode = keyCode
        AppSettings.standard.hotkeyModifiers = carbonModifiers
        hotkeyRecorder?.setKeys(HotkeyManager.displayString(keyCode: keyCode, modifiers: carbonModifiers))
        onHotkeyChange?(keyCode, carbonModifiers)
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Read Along Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 700, height: 660)
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = ReaderTheme.canvas.cgColor
        window.contentView = content

        let backdrop = BackdropView()
        content.addSubview(backdrop)

        let kicker = Widget.microLabel("SETTINGS", color: ReaderTheme.amber)
        let title = Widget.displayLabel("Make it yours.", size: 34, weight: .thin)
        let subtitle = Widget.bodyLabel(
            "The engine, the microphone, the shortcut, and the floating widget.",
            size: 12
        )
        content.addSubview(kicker)
        content.addSubview(title)
        content.addSubview(subtitle)

        // Model card
        let modelCard = Widget.card()
        let modelKicker = Widget.microLabel("SPEECH MODEL")
        let modelField = NSTextField()
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.stringValue = AppSettings.standard.model
        modelField.font = ReaderTheme.display(size: 24, weight: .light)
        modelField.textColor = ReaderTheme.textPrimary
        modelField.isBordered = false
        modelField.drawsBackground = false
        modelField.focusRingType = .none
        modelField.delegate = self
        modelField.placeholderString = "phonon-2"
        self.modelField = modelField

        let modelWell = NSView()
        modelWell.translatesAutoresizingMaskIntoConstraints = false
        modelWell.wantsLayer = true
        modelWell.layer?.backgroundColor = ReaderTheme.inset.cgColor
        modelWell.layer?.cornerRadius = 12
        modelWell.layer?.borderWidth = 1
        modelWell.layer?.borderColor = ReaderTheme.hairline.cgColor
        modelWell.addSubview(modelField)

        let modelHint = Widget.microLabel("CHANGING IT RESTARTS THE ENGINE", size: 9)

        modelCard.addSubview(modelKicker)
        modelCard.addSubview(modelWell)
        modelCard.addSubview(modelHint)

        // Hotkey card
        let hotkeyCard = Widget.card()
        let hotkeyKicker = Widget.microLabel("START HOTKEY")
        let recorder = HotkeyRecorderView()
        recorder.onRecord = { [weak self] keyCode, modifiers in
            self?.recordHotkey(keyCode: keyCode, carbonModifiers: modifiers)
        }
        hotkeyRecorder = recorder
        let hotkeyHint = Widget.microLabel("CLICK TO RECORD · USED GLOBALLY", size: 9)

        hotkeyCard.addSubview(hotkeyKicker)
        hotkeyCard.addSubview(recorder)
        hotkeyCard.addSubview(hotkeyHint)

        // Microphone card
        let micCard = Widget.card()
        let micKicker = Widget.microLabel("MICROPHONE")
        let picker = NSPopUpButton()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.controlSize = .large
        picker.font = ReaderTheme.interfaceFont(size: 13)
        picker.target = self
        picker.action = #selector(microphoneChanged)
        picker.addItem(withTitle: "System default")
        micPicker = picker
        let hint = Widget.microLabel("USING", size: 9)
        hint.lineBreakMode = .byTruncatingTail
        micHint = hint

        micCard.addSubview(micKicker)
        micCard.addSubview(picker)
        micCard.addSubview(hint)

        // Status card
        let statusCard = Widget.card()
        let statusKicker = Widget.microLabel("STATUS CARD")
        let statusTitle = Widget.titleLabel("Floating session widget", size: 15)
        let statusBody = Widget.bodyLabel(
            "Shows the engine state while you read in other apps.",
            size: 11
        )
        let cardSwitch = PillSwitch()
        cardSwitch.onToggle = { [weak self] isOn in self?.toggleCard(isOn) }
        self.cardSwitch = cardSwitch

        statusCard.addSubview(statusKicker)
        statusCard.addSubview(statusTitle)
        statusCard.addSubview(statusBody)
        statusCard.addSubview(cardSwitch)

        // About card
        let aboutCard = Widget.card()
        let aboutKicker = Widget.microLabel("ABOUT")
        let aboutTitle = Widget.displayLabel("Read Along", size: 20, weight: .light)
        let aboutBody = Widget.bodyLabel("Local speech. No cloud. English.", size: 11)
        let version = Widget.microLabel("VERSION 1.0 · PHONON-2", size: 9)

        aboutCard.addSubview(aboutKicker)
        aboutCard.addSubview(aboutTitle)
        aboutCard.addSubview(aboutBody)
        aboutCard.addSubview(version)

        content.addSubview(modelCard)
        content.addSubview(hotkeyCard)
        content.addSubview(micCard)
        content.addSubview(statusCard)
        content.addSubview(aboutCard)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            kicker.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            kicker.topAnchor.constraint(equalTo: content.topAnchor, constant: 56),

            title.leadingAnchor.constraint(equalTo: kicker.leadingAnchor),
            title.topAnchor.constraint(equalTo: kicker.bottomAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: kicker.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            modelCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            modelCard.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            modelCard.heightAnchor.constraint(equalToConstant: 200),

            hotkeyCard.leadingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: 16),
            hotkeyCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            hotkeyCard.topAnchor.constraint(equalTo: modelCard.topAnchor),
            hotkeyCard.heightAnchor.constraint(equalTo: modelCard.heightAnchor),
            hotkeyCard.widthAnchor.constraint(equalTo: modelCard.widthAnchor),

            micCard.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor),
            micCard.trailingAnchor.constraint(equalTo: hotkeyCard.trailingAnchor),
            micCard.topAnchor.constraint(equalTo: modelCard.bottomAnchor, constant: 16),
            micCard.heightAnchor.constraint(equalToConstant: 100),

            statusCard.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor),
            statusCard.topAnchor.constraint(equalTo: micCard.bottomAnchor, constant: 16),
            statusCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),

            aboutCard.leadingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: 16),
            aboutCard.trailingAnchor.constraint(equalTo: hotkeyCard.trailingAnchor),
            aboutCard.topAnchor.constraint(equalTo: statusCard.topAnchor),
            aboutCard.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),
            aboutCard.widthAnchor.constraint(equalTo: statusCard.widthAnchor),

            // Model content
            modelKicker.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            modelKicker.topAnchor.constraint(equalTo: modelCard.topAnchor, constant: 20),

            modelWell.leadingAnchor.constraint(equalTo: modelKicker.leadingAnchor),
            modelWell.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -20),
            modelWell.topAnchor.constraint(equalTo: modelKicker.bottomAnchor, constant: 12),
            modelWell.heightAnchor.constraint(equalToConstant: 54),

            modelField.leadingAnchor.constraint(equalTo: modelWell.leadingAnchor, constant: 14),
            modelField.trailingAnchor.constraint(equalTo: modelWell.trailingAnchor, constant: -14),
            modelField.centerYAnchor.constraint(equalTo: modelWell.centerYAnchor),

            modelHint.leadingAnchor.constraint(equalTo: modelKicker.leadingAnchor),
            modelHint.bottomAnchor.constraint(equalTo: modelCard.bottomAnchor, constant: -20),

            // Hotkey content
            hotkeyKicker.leadingAnchor.constraint(equalTo: hotkeyCard.leadingAnchor, constant: 20),
            hotkeyKicker.topAnchor.constraint(equalTo: hotkeyCard.topAnchor, constant: 20),

            recorder.leadingAnchor.constraint(equalTo: hotkeyKicker.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: hotkeyCard.trailingAnchor, constant: -20),
            recorder.topAnchor.constraint(equalTo: hotkeyKicker.bottomAnchor, constant: 12),
            recorder.heightAnchor.constraint(equalToConstant: 82),

            hotkeyHint.leadingAnchor.constraint(equalTo: hotkeyKicker.leadingAnchor),
            hotkeyHint.bottomAnchor.constraint(equalTo: hotkeyCard.bottomAnchor, constant: -20),

            // Microphone content
            micKicker.leadingAnchor.constraint(equalTo: micCard.leadingAnchor, constant: 20),
            micKicker.topAnchor.constraint(equalTo: micCard.topAnchor, constant: 18),

            picker.leadingAnchor.constraint(equalTo: micKicker.leadingAnchor),
            picker.topAnchor.constraint(equalTo: micKicker.bottomAnchor, constant: 8),
            picker.widthAnchor.constraint(equalToConstant: 300),

            hint.leadingAnchor.constraint(equalTo: picker.trailingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: micCard.trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: picker.centerYAnchor),

            // Status content
            statusKicker.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 20),
            statusKicker.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 18),

            statusTitle.leadingAnchor.constraint(equalTo: statusKicker.leadingAnchor),
            statusTitle.topAnchor.constraint(equalTo: statusKicker.bottomAnchor, constant: 8),

            statusBody.leadingAnchor.constraint(equalTo: statusKicker.leadingAnchor),
            statusBody.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 4),
            statusBody.trailingAnchor.constraint(lessThanOrEqualTo: cardSwitch.leadingAnchor, constant: -16),

            cardSwitch.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -20),
            cardSwitch.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),
            cardSwitch.widthAnchor.constraint(equalToConstant: 46),
            cardSwitch.heightAnchor.constraint(equalToConstant: 26),

            // About content
            aboutKicker.leadingAnchor.constraint(equalTo: aboutCard.leadingAnchor, constant: 20),
            aboutKicker.topAnchor.constraint(equalTo: aboutCard.topAnchor, constant: 18),

            aboutTitle.leadingAnchor.constraint(equalTo: aboutKicker.leadingAnchor),
            aboutTitle.topAnchor.constraint(equalTo: aboutKicker.bottomAnchor, constant: 8),

            aboutBody.leadingAnchor.constraint(equalTo: aboutKicker.leadingAnchor),
            aboutBody.topAnchor.constraint(equalTo: aboutTitle.bottomAnchor, constant: 3),

            version.leadingAnchor.constraint(equalTo: aboutKicker.leadingAnchor),
            version.bottomAnchor.constraint(equalTo: aboutCard.bottomAnchor, constant: -20),
        ])

        return window
    }
}

/// Click to arm, press the combination, done. Esc while armed cancels.
@MainActor
final class HotkeyRecorderView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?
    private let keys = KeycapsView()
    private let promptLabel = Widget.microLabel("CLICK TO RECORD", size: 9)

    var isRecording = false {
        didSet {
            promptLabel.attributedStringValue = ReaderTheme.micro(
                isRecording ? "PRESS KEYS…" : "CLICK TO RECORD",
                color: isRecording ? ReaderTheme.amber : ReaderTheme.textSecondary,
                size: 9
            )
            layer?.borderColor = (isRecording ? ReaderTheme.amber : ReaderTheme.hairline).cgColor
            needsDisplay = true
            if isRecording {
                window?.makeFirstResponder(self)
            }
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ReaderTheme.inset.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = ReaderTheme.hairline.cgColor

        addSubview(keys)
        addSubview(promptLabel)

        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            promptLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("HotkeyRecorderView is built in code")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = !isRecording
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc cancels recording.
            isRecording = false
            return
        }
        let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
        // A shortcut without a system modifier risks swallowing plain typing.
        guard modifiers != 0 else { return }
        isRecording = false
        onRecord?(UInt32(event.keyCode), modifiers)
    }

    func setKeys(_ display: String) {
        keys.setKeys(display)
    }
}

/// A small amber capsule switch used for the status-card setting.
@MainActor
final class PillSwitch: NSView {
    var onToggle: ((Bool) -> Void)?

    var isOn = false {
        didSet { update() }
    }

    private let knob = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        layer?.borderColor = ReaderTheme.hairline.cgColor

        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.wantsLayer = true
        knob.layer?.cornerRadius = 9
        knob.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        addSubview(knob)

        NSLayoutConstraint.activate([
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: 18),
            knob.heightAnchor.constraint(equalToConstant: 18),
        ])
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("PillSwitch is built in code")
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }

    private func update() {
        layer?.backgroundColor = (isOn ? ReaderTheme.amber : ReaderTheme.inset).cgColor
        let offset: CGFloat = isOn ? 24 : 4
        for constraint in constraints where constraint.firstItem === knob && constraint.firstAttribute == .leading {
            constraint.isActive = false
        }
        knob.leadingAnchor.constraint(equalTo: leadingAnchor, constant: offset).isActive = true
    }
}
