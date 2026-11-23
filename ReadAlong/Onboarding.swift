import AppKit
import AVFoundation

/// The gated first-run experience: permissions with live status, speech
/// engine setup with progress, and the how-to. Shown again whenever a
/// required permission is missing at launch.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let engine: SpeechEngine
    private var window: NSWindow?
    private var micRow: PermissionRow?
    private var screenRow: PermissionRow?
    private var accessibilityRow: PermissionRow?
    private var engineStatusLabel: NSTextField?
    private var engineButton: NSButton?
    private var continueButton: NSButton?

    init(engine: SpeechEngine) {
        self.engine = engine
        super.init()

        engine.addObserver(
            id: ObjectIdentifier(self),
            onState: { [weak self] state in self?.handleEngineState(state) }
        )
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refreshPermissions()
    }

    // MARK: - Permission rows

    private func refreshPermissions() {
        micRow?.update(
            granted: Permissions.microphoneGranted(),
            denied: AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        )
        screenRow?.update(granted: Permissions.screenRecordingGranted(), denied: true)
        accessibilityRow?.update(granted: Permissions.accessibilityGranted(), denied: false)
    }

    @objc private func grantMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.refreshPermissions()
            }
        } else {
            Permissions.openMicrophonePane()
        }
    }

    @objc private func grantScreenRecording() {
        Permissions.openScreenRecordingPane()
    }

    @objc private func grantAccessibility() {
        Permissions.promptForAccessibility()
    }

    // MARK: - Engine setup

    @objc private func startEngineSetup() {
        engineButton?.isEnabled = false
        engineStatusLabel?.stringValue = "Setting up the speech engine…"
        Task { @MainActor in
            do {
                try await self.engine.prepare()
                self.engineStatusLabel?.stringValue = "Ready"
            } catch {
                self.engineStatusLabel?.stringValue = error.localizedDescription
                self.engineButton?.isEnabled = true
            }
        }
    }

    private func handleEngineState(_ state: SpeechEngineState) {
        guard window?.isVisible == true else { return }
        switch state {
        case .starting(let message):
            engineStatusLabel?.stringValue = message
        case .listening:
            engineStatusLabel?.stringValue = "Ready — engine running"
        case .failed(let message):
            engineStatusLabel?.stringValue = message
            engineButton?.isEnabled = true
        case .idle:
            break
        }
    }

    @objc private func finish() {
        AppSettings.standard.onboardingCompleted = true
        window?.orderOut(nil)
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Read Along"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let micRow = PermissionRow(title: "Microphone", required: true) { [weak self] in
            self?.grantMicrophone()
        }
        let screenRow = PermissionRow(title: "Screen Recording", required: true) { [weak self] in
            self?.grantScreenRecording()
        }
        let accessibilityRow = PermissionRow(title: "Accessibility", required: false) { [weak self] in
            self?.grantAccessibility()
        }
        self.micRow = micRow
        self.screenRow = screenRow
        self.accessibilityRow = accessibilityRow

        let engineStatusLabel = NSTextField(labelWithString: "Not set up yet")
        engineStatusLabel.font = ReaderTheme.interfaceFont(size: 12)
        engineStatusLabel.textColor = ReaderTheme.textSecondary
        self.engineStatusLabel = engineStatusLabel

        let engineButton = NSButton(title: "Set Up Speech Engine", target: self, action: #selector(startEngineSetup))
        engineButton.bezelColor = ReaderTheme.readingStroke
        self.engineButton = engineButton

        let hotkey = HotkeyManager.displayString(
            keyCode: AppSettings.standard.hotkeyCode,
            modifiers: AppSettings.standard.hotkeyModifiers
        )

        let howTo = NSTextField(wrappingLabelWithString: """
        Press \(hotkey) to start a session, click the window you are reading, \
        and read aloud. The sentence under your voice glows amber and the next \
        one waits faintly. Finish a sentence and the glow advances; a three-word \
        phrase jumps ahead or back; stray words never move it. Open local text, \
        Markdown or PDF files from the menu bar any time.
        """)
        howTo.font = ReaderTheme.interfaceFont(size: 12)
        howTo.textColor = ReaderTheme.textSecondary

        let continueButton = NSButton(title: "Start Reading", target: self, action: #selector(finish))
        continueButton.bezelColor = ReaderTheme.readingStroke
        continueButton.keyEquivalent = "\r"
        self.continueButton = continueButton

        let stack = NSStackView(views: [
            sectionTitle("1 · Permissions"),
            micRow,
            screenRow,
            accessibilityRow,
            sectionTitle("2 · Speech engine"),
            engineStatusLabel,
            engineButton,
            sectionTitle("3 · How to read"),
            howTo,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(continueButton)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            continueButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            continueButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            continueButton.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 8),
        ])

        return window
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ReaderTheme.interfaceFont(size: 13, weight: .semibold)
        label.textColor = ReaderTheme.textPrimary
        return label
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Granting in System Settings only takes effect after relaunch for
        // screen recording, but refreshing on focus keeps statuses honest.
        refreshPermissions()
    }
}

/// One permission line: name, requiredness, live status, and a fix button.
@MainActor
private final class PermissionRow: NSView {
    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var grantHandler: (() -> Void)?

    init(title: String, required: Bool, onGrant: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let nameLabel = NSTextField(labelWithString: title)
        nameLabel.font = ReaderTheme.interfaceFont(size: 13, weight: .medium)
        nameLabel.textColor = ReaderTheme.textPrimary

        statusLabel.font = ReaderTheme.interfaceFont(size: 12)
        statusLabel.textColor = ReaderTheme.textSecondary

        let button = NSButton(
            title: required ? "Grant…" : "Turn On…",
            target: nil,
            action: nil
        )
        button.bezelColor = ReaderTheme.readingStroke
        grantHandler = onGrant
        button.target = self
        button.action = #selector(grantTapped)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = ReaderTheme.danger.cgColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PermissionRow is built in code")
    }

    @objc private func grantTapped() {
        grantHandler?()
    }

    func update(granted: Bool, denied: Bool) {
        if granted {
            dot.layer?.backgroundColor = ReaderTheme.readingStroke.cgColor
            statusLabel.stringValue = "Granted"
        } else if denied {
            dot.layer?.backgroundColor = ReaderTheme.danger.cgColor
            statusLabel.stringValue = "Missing — see System Settings"
        } else {
            dot.layer?.backgroundColor = ReaderTheme.textSecondary.cgColor
            statusLabel.stringValue = "Not yet allowed"
        }
    }
}
