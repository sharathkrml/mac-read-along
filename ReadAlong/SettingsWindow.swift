import AppKit

/// The Settings window: model name, start hotkey, status-card visibility.
/// All values persist; changing the model restarts a running engine.
@MainActor
final class SettingsController: NSObject, NSTextFieldDelegate {
    var onModelChange: (() -> Void)?
    var onHotkeyChange: ((UInt32, UInt32) -> Void)?
    var onCardVisibilityChange: (() -> Void)?

    private var window: NSWindow?
    private var modelField: NSTextField?
    private var cardCheckbox: NSButton?
    private var hotkeyLabel: NSTextField?
    private var hotkeyRecorder: HotkeyRecorderView?

    func show() {
        if window == nil {
            window = makeWindow()
        }
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func refresh() {
        modelField?.stringValue = AppSettings.standard.model
        hotkeyLabel?.stringValue = HotkeyManager.displayString(
            keyCode: AppSettings.standard.hotkeyCode,
            modifiers: AppSettings.standard.hotkeyModifiers
        )
        hotkeyRecorder?.isRecording = false
        cardCheckbox?.state = AppSettings.standard.cardVisible ? .on : .off
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

    @objc private func toggleCard() {
        AppSettings.standard.cardVisible = cardCheckbox?.state == .on
        onCardVisibilityChange?()
    }

    private func recordHotkey(keyCode: UInt32, carbonModifiers: UInt32) {
        AppSettings.standard.hotkeyCode = keyCode
        AppSettings.standard.hotkeyModifiers = carbonModifiers
        hotkeyLabel?.stringValue = HotkeyManager.displayString(keyCode: keyCode, modifiers: carbonModifiers)
        onHotkeyChange?(keyCode, carbonModifiers)
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Read Along Settings"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false

        let modelLabel = sectionTitle("Speech model")
        let modelField = NSTextField()
        modelField.font = ReaderTheme.interfaceFont(size: 13)
        modelField.textColor = ReaderTheme.textPrimary
        modelField.backgroundColor = ReaderTheme.surface
        modelField.bezelStyle = .roundedBezel
        modelField.delegate = self
        self.modelField = modelField

        let modelHint = hint("Model names match fermion's serve models, e.g. phonon-2. Changing it restarts a running engine.")

        let hotkeyLabel = sectionTitle("Start hotkey")
        let hotkeyRecorder = HotkeyRecorderView()
        self.hotkeyRecorder = hotkeyRecorder
        hotkeyRecorder.onRecord = { [weak self] keyCode, modifiers in
            self?.recordHotkey(keyCode: keyCode, carbonModifiers: modifiers)
        }
        self.hotkeyLabel = hotkeyRecorder.label

        let cardLabel = sectionTitle("Status card")
        let cardCheckbox = NSButton(
            title: "Show the floating status card during sessions",
            target: self,
            action: #selector(toggleCard)
        )
        cardCheckbox.setButtonType(.switch)
        cardCheckbox.font = ReaderTheme.interfaceFont(size: 12)
        self.cardCheckbox = cardCheckbox

        let stack = NSStackView(views: [
            modelLabel, modelField, modelHint,
            hotkeyLabel, hotkeyRecorder,
            cardLabel, cardCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)

        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            modelField.widthAnchor.constraint(equalToConstant: 220),
            hotkeyRecorder.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])

        return window
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ReaderTheme.interfaceFont(size: 13, weight: .semibold)
        label.textColor = ReaderTheme.textPrimary
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = ReaderTheme.interfaceFont(size: 11)
        field.textColor = ReaderTheme.textSecondary
        field.preferredMaxLayoutWidth = 400
        return field
    }
}

/// Click to arm, press the combination, done. Esc while armed cancels.
@MainActor
private final class HotkeyRecorderView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?

    let label = NSTextField(labelWithString: "")

    var isRecording = false {
        didSet {
            label.stringValue = isRecording ? "Press keys…" : HotkeyManager.displayString(
                keyCode: AppSettings.standard.hotkeyCode,
                modifiers: AppSettings.standard.hotkeyModifiers
            )
            needsDisplay = true
            if isRecording {
                window?.makeFirstResponder(self)
            }
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ReaderTheme.surface.cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = ReaderTheme.readingStroke.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReaderTheme.interfaceFont(size: 13, weight: .medium)
        label.textColor = ReaderTheme.textPrimary
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
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
}
