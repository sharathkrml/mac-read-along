import AppKit
import AVFoundation

/// The gated first-run experience: permissions with live status, an engine
/// that loads itself, and a live microphone test with waveform and transcript.
/// Shown again whenever a required permission is missing at launch.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let engine: SpeechEngine
    /// Called when the user leaves the launcher to pick a window to read.
    var onStartReading: (() -> Void)?
    private var window: NSWindow?
    private var micRow: PermissionRow?
    private var screenRow: PermissionRow?
    private var accessibilityRow: PermissionRow?
    private var engineStatusLabel: NSTextField?
    private var engineDetailLabel: NSTextField?
    private var engineActivity: ActivityBars?
    private var engineButton: PillButton?
    private var continueButton: PillButton?
    private var waveform: WaveformView?
    private var transcriptLabel: NSTextField?
    private var testStatusLabel: NSTextField?
    private var cards: [NSView] = []
    private var enginePrepared = false
    private var preparing = false
    private var testStarting = false
    /// True while this window is open; the mic test must not outlive it.
    private var testEnabled = false

    private static let transcriptPlaceholder = "Your words appear here as you speak."

    init(engine: SpeechEngine) {
        self.engine = engine
        super.init()

        engine.addObserver(
            id: ObjectIdentifier(self),
            onState: { [weak self] state in self?.handleEngineState(state) },
            onTranscript: { [weak self] update in self?.handleTranscript(update) },
            onLevel: { [weak self] level in self?.handleLevel(level) }
        )
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        testEnabled = true
        window?.ensureOnVisibleScreen()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refreshPermissions()
        startEngine()
        animateCards()
    }

    /// Leaves the front door open behind the picker when a session starts.
    func hide() {
        endTest()
        window?.orderOut(nil)
    }

    // MARK: - Permission rows

    private func refreshPermissions() {
        micRow?.update(
            granted: Permissions.microphoneGranted(),
            denied: AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        )
        screenRow?.update(granted: Permissions.screenRecordingGranted(), denied: true)
        accessibilityRow?.update(granted: Permissions.accessibilityGranted(), denied: false)
        updateStartButton()
    }

    @objc private func grantMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.refreshPermissions()
                self.startTestIfPossible()
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

    // MARK: - Engine setup and mic test

    /// The model loads itself as soon as the window appears; nothing to click.
    private func startEngine() {
        if case .listening = engine.state {
            enginePrepared = true
            startTestIfPossible()
            return
        }
        prepareEngine()
    }

    private func prepareEngine() {
        guard !preparing, engine.state != .listening else { return }
        if case .starting = engine.state { return }
        preparing = true
        engineButton?.isEnabled = false
        engineButton?.title = "Setting up…"
        engineStatusLabel?.stringValue = "Loading"
        engineDetailLabel?.stringValue = "\(AppSettings.standard.model.uppercased()) · ENGLISH"
        engineActivity?.isActive = true
        testStatusLabel?.attributedStringValue = ReaderTheme.micro("STARTING THE ENGINE", size: 9)
        updateStartButton()

        Task { @MainActor in
            do {
                try await self.engine.prepare()
                self.enginePrepared = true
                // prepare() can leave the engine in a starting state; clear it
                // so the mic test can open a fresh stream.
                self.engine.stop()
                self.preparing = false
                self.engineStatusLabel?.stringValue = "Ready"
                self.engineDetailLabel?.stringValue = "\(AppSettings.standard.model.uppercased()) · ENGLISH"
                self.engineButton?.title = "Ready"
                self.engineButton?.isEnabled = false
                self.engineActivity?.isActive = false
                self.updateStartButton()
                self.startTestIfPossible()
            } catch {
                self.engine.stop()
                self.preparing = false
                self.engineStatusLabel?.stringValue = "Error"
                self.engineDetailLabel?.stringValue = error.localizedDescription
                self.engineButton?.title = "Retry"
                self.engineButton?.isEnabled = true
                self.engineActivity?.isActive = false
                self.updateStartButton()
                self.testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                    "ENGINE UNAVAILABLE",
                    color: ReaderTheme.danger,
                    size: 9
                )
            }
        }
    }

    /// Opens the mic for the test only while this window is up, and only after
    /// the model is ready and the microphone has been granted.
    private func startTestIfPossible() {
        guard testEnabled, !preparing, window?.isVisible == true, enginePrepared else { return }
        if engine.state == .listening {
            testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                "LISTENING · SAY ANYTHING",
                color: ReaderTheme.amber,
                size: 9
            )
            return
        }
        guard !testStarting else { return }
        guard Permissions.microphoneGranted() else {
            testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                "GRANT THE MICROPHONE TO TEST",
                color: ReaderTheme.textSecondary,
                size: 9
            )
            return
        }

        testStarting = true
        testStatusLabel?.attributedStringValue = ReaderTheme.micro(
            "STARTING THE MICROPHONE",
            color: ReaderTheme.amber,
            size: 9
        )
        Task { @MainActor in
            defer { self.testStarting = false }
            do {
                try await self.engine.start(owner: ObjectIdentifier(self))
            } catch {
                self.testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                    "MICROPHONE UNAVAILABLE",
                    color: ReaderTheme.danger,
                    size: 9
                )
                self.transcriptLabel?.stringValue = error.localizedDescription
                self.transcriptLabel?.textColor = ReaderTheme.danger
            }
        }
    }

    private func handleTranscript(_ update: TranscriptUpdate) {
        guard testEnabled, window?.isVisible == true else { return }
        transcriptLabel?.stringValue = update.text
        transcriptLabel?.textColor = update.isFinal ? ReaderTheme.textPrimary : ReaderTheme.textSecondary
    }

    private func handleLevel(_ level: Float) {
        guard testEnabled, window?.isVisible == true else { return }
        waveform?.add(level)
    }

    private func handleEngineState(_ state: SpeechEngineState) {
        guard window?.isVisible == true else { return }
        switch state {
        case .starting(let message):
            engineStatusLabel?.stringValue = "Loading"
            engineDetailLabel?.stringValue = message
            engineActivity?.isActive = true
            if !enginePrepared {
                testStatusLabel?.attributedStringValue = ReaderTheme.micro("STARTING THE ENGINE", size: 9)
            }
        case .listening:
            enginePrepared = true
            engineStatusLabel?.stringValue = "Ready"
            engineDetailLabel?.stringValue = "\(AppSettings.standard.model.uppercased()) · ENGLISH"
            engineActivity?.isActive = false
            engineButton?.title = "Ready"
            engineButton?.isEnabled = false
            testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                "LISTENING · SAY ANYTHING",
                color: ReaderTheme.amber,
                size: 9
            )
        case .failed(let message):
            engineActivity?.isActive = false
            waveform?.reset()
            if enginePrepared {
                // The model is fine; only this test stream stopped.
                testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                    "VOICE TEST STOPPED",
                    color: ReaderTheme.danger,
                    size: 9
                )
                transcriptLabel?.stringValue = message
                transcriptLabel?.textColor = ReaderTheme.danger
                engineButton?.title = "Retry"
                engineButton?.isEnabled = true
            } else {
                engineStatusLabel?.stringValue = "Error"
                engineDetailLabel?.stringValue = message
                engineButton?.title = "Retry"
                engineButton?.isEnabled = true
                testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                    "ENGINE UNAVAILABLE",
                    color: ReaderTheme.danger,
                    size: 9
                )
            }
        case .idle:
            waveform?.reset()
            testStatusLabel?.attributedStringValue = ReaderTheme.micro(
                enginePrepared ? "MICROPHONE OFF" : "WAITING FOR THE ENGINE",
                color: ReaderTheme.textSecondary,
                size: 9
            )
            if enginePrepared {
                engineStatusLabel?.stringValue = "Ready"
                engineDetailLabel?.stringValue = "\(AppSettings.standard.model.uppercased()) · ENGLISH"
                startTestIfPossible()
            }
        }
        updateStartButton()
    }

    /// The session needs the model, the microphone, and screen recording.
    private func updateStartButton() {
        let permitted = Permissions.microphoneGranted() && Permissions.screenRecordingGranted()
        continueButton?.isEnabled = enginePrepared && permitted
        if !permitted {
            continueButton?.title = "Grant permissions"
        } else if !enginePrepared {
            continueButton?.title = "Preparing…"
        } else {
            continueButton?.title = "Start reading"
        }
    }

    /// Stops the test stream if this window was the one that opened it; a
    /// read-along session keeps its own stream running.
    private func endTest() {
        testEnabled = false
        if engine.streamOwner == ObjectIdentifier(self) {
            engine.stop()
        }
        waveform?.reset()
        transcriptLabel?.stringValue = Self.transcriptPlaceholder
        transcriptLabel?.textColor = ReaderTheme.textTertiary
        testStatusLabel?.attributedStringValue = ReaderTheme.micro("MICROPHONE OFF", size: 9)
    }

    @objc private func startReading() {
        guard enginePrepared,
              Permissions.microphoneGranted(),
              Permissions.screenRecordingGranted() else { return }
        endTest()
        onStartReading?()
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Read Along"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 860, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = ReaderTheme.canvas.cgColor
        window.contentView = content

        let backdrop = BackdropView()
        content.addSubview(backdrop)

        // Header
        let kicker = Widget.microLabel("READ ALONG · SETUP", color: ReaderTheme.amber)
        let title = Widget.displayLabel("Settle in.", size: 44, weight: .thin)
        let subtitle = Widget.bodyLabel(
            "A quiet reading surface that follows your voice. Grant two permissions, then say a few words to test the local engine.",
            size: 13
        )
        let privacy = Widget.capsuleLabel("LOCAL · PRIVATE", tint: ReaderTheme.textSecondary)

        content.addSubview(kicker)
        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(privacy)

        // Permissions widget
        let permissions = Widget.card()
        let permissionKicker = Widget.microLabel("01 · PERMISSIONS")
        let permissionTitle = Widget.titleLabel("Let it hear you.", size: 18)

        let micRow = PermissionRow(
            title: "Microphone",
            symbol: "mic",
            onGrant: { [weak self] in self?.grantMicrophone() }
        )
        let screenRow = PermissionRow(
            title: "Screen Recording",
            symbol: "rectangle.dashed",
            onGrant: { [weak self] in self?.grantScreenRecording() }
        )
        let accessibilityRow = PermissionRow(
            title: "Accessibility",
            symbol: "accessibility",
            onGrant: { [weak self] in self?.grantAccessibility() }
        )
        self.micRow = micRow
        self.screenRow = screenRow
        self.accessibilityRow = accessibilityRow

        permissions.addSubview(permissionKicker)
        permissions.addSubview(permissionTitle)
        permissions.addSubview(micRow)
        permissions.addSubview(screenRow)
        permissions.addSubview(accessibilityRow)

        // Engine widget
        let engineCard = Widget.card()
        let engineKicker = Widget.microLabel("02 · SPEECH ENGINE")
        let engineTitle = Widget.displayLabel("Loading", size: 32, weight: .light)
        let engineDetail = Widget.bodyLabel(
            "\(AppSettings.standard.model.uppercased()) · ENGLISH",
            size: 11
        )
        let activity = ActivityBars()
        activity.isActive = true
        let engineButton = PillButton("Setting up…", kind: .primary)
        engineButton.isEnabled = false
        engineButton.onPress = { [weak self] in self?.prepareEngine() }
        engineButton.font = ReaderTheme.interfaceFont(size: 12, weight: .semibold)

        engineStatusLabel = engineTitle
        engineDetailLabel = engineDetail
        engineActivity = activity
        self.engineButton = engineButton

        engineCard.addSubview(engineKicker)
        engineCard.addSubview(engineTitle)
        engineCard.addSubview(engineDetail)
        engineCard.addSubview(activity)
        engineCard.addSubview(engineButton)

        // Mic test widget
        let micTest = Widget.card()
        let testKicker = Widget.microLabel("03 · TRY YOUR VOICE")
        let waveform = WaveformView()
        let transcript = NSTextField(wrappingLabelWithString: Self.transcriptPlaceholder)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.font = ReaderTheme.interfaceFont(size: 14)
        transcript.textColor = ReaderTheme.textTertiary
        transcript.maximumNumberOfLines = 2
        transcript.lineBreakMode = .byTruncatingTail
        let testStatus = Widget.microLabel("WAITING FOR THE ENGINE", size: 9)

        self.waveform = waveform
        transcriptLabel = transcript
        testStatusLabel = testStatus

        micTest.addSubview(testKicker)
        micTest.addSubview(waveform)
        micTest.addSubview(transcript)
        micTest.addSubview(testStatus)

        // Ready widget
        let ready = Widget.card()
        let readyKicker = Widget.microLabel("READY WHEN YOU ARE")
        let readyTitle = Widget.displayLabel("Go.", size: 40, weight: .thin)
        let hotkey = HotkeyManager.displayString(
            keyCode: AppSettings.standard.hotkeyCode,
            modifiers: AppSettings.standard.hotkeyModifiers
        )
        let readyHint = Widget.bodyLabel(
            "Start reading, then click the browser or PDF window you want to follow. \(hotkey) does the same from anywhere.",
            size: 11
        )
        let startButton = PillButton("Start reading", kind: .primary)
        startButton.isEnabled = false
        startButton.onPress = { [weak self] in self?.startReading() }
        continueButton = startButton

        ready.addSubview(readyKicker)
        ready.addSubview(readyTitle)
        ready.addSubview(readyHint)
        ready.addSubview(startButton)

        content.addSubview(permissions)
        content.addSubview(engineCard)
        content.addSubview(micTest)
        content.addSubview(ready)
        cards = [permissions, engineCard, micTest, ready]

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
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: privacy.leadingAnchor, constant: -24),

            privacy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            privacy.topAnchor.constraint(equalTo: content.topAnchor, constant: 60),

            permissions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            permissions.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            permissions.heightAnchor.constraint(equalToConstant: 268),

            engineCard.leadingAnchor.constraint(equalTo: permissions.trailingAnchor, constant: 16),
            engineCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            engineCard.topAnchor.constraint(equalTo: permissions.topAnchor),
            engineCard.heightAnchor.constraint(equalTo: permissions.heightAnchor),
            engineCard.widthAnchor.constraint(equalTo: permissions.widthAnchor),

            micTest.leadingAnchor.constraint(equalTo: permissions.leadingAnchor),
            micTest.widthAnchor.constraint(equalTo: permissions.widthAnchor),
            micTest.topAnchor.constraint(equalTo: permissions.bottomAnchor, constant: 16),
            micTest.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),

            ready.leadingAnchor.constraint(equalTo: micTest.trailingAnchor, constant: 16),
            ready.trailingAnchor.constraint(equalTo: engineCard.trailingAnchor),
            ready.topAnchor.constraint(equalTo: micTest.topAnchor),
            ready.bottomAnchor.constraint(equalTo: micTest.bottomAnchor),

            // Permissions content
            permissionKicker.leadingAnchor.constraint(equalTo: permissions.leadingAnchor, constant: 20),
            permissionKicker.topAnchor.constraint(equalTo: permissions.topAnchor, constant: 20),

            permissionTitle.leadingAnchor.constraint(equalTo: permissionKicker.leadingAnchor),
            permissionTitle.topAnchor.constraint(equalTo: permissionKicker.bottomAnchor, constant: 6),

            micRow.leadingAnchor.constraint(equalTo: permissions.leadingAnchor, constant: 20),
            micRow.trailingAnchor.constraint(equalTo: permissions.trailingAnchor, constant: -20),
            micRow.topAnchor.constraint(equalTo: permissionTitle.bottomAnchor, constant: 10),
            micRow.heightAnchor.constraint(equalToConstant: 48),

            screenRow.leadingAnchor.constraint(equalTo: micRow.leadingAnchor),
            screenRow.trailingAnchor.constraint(equalTo: micRow.trailingAnchor),
            screenRow.topAnchor.constraint(equalTo: micRow.bottomAnchor, constant: 4),
            screenRow.heightAnchor.constraint(equalToConstant: 48),

            accessibilityRow.leadingAnchor.constraint(equalTo: micRow.leadingAnchor),
            accessibilityRow.trailingAnchor.constraint(equalTo: micRow.trailingAnchor),
            accessibilityRow.topAnchor.constraint(equalTo: screenRow.bottomAnchor, constant: 4),
            accessibilityRow.heightAnchor.constraint(equalToConstant: 48),

            // Engine content
            engineKicker.leadingAnchor.constraint(equalTo: engineCard.leadingAnchor, constant: 20),
            engineKicker.topAnchor.constraint(equalTo: engineCard.topAnchor, constant: 20),

            activity.trailingAnchor.constraint(equalTo: engineCard.trailingAnchor, constant: -20),
            activity.centerYAnchor.constraint(equalTo: engineKicker.centerYAnchor),

            engineTitle.leadingAnchor.constraint(equalTo: engineKicker.leadingAnchor),
            engineTitle.topAnchor.constraint(equalTo: engineKicker.bottomAnchor, constant: 14),

            engineDetail.leadingAnchor.constraint(equalTo: engineKicker.leadingAnchor),
            engineDetail.topAnchor.constraint(equalTo: engineTitle.bottomAnchor, constant: 4),
            engineDetail.trailingAnchor.constraint(lessThanOrEqualTo: engineCard.trailingAnchor, constant: -20),

            engineButton.leadingAnchor.constraint(equalTo: engineKicker.leadingAnchor),
            engineButton.bottomAnchor.constraint(equalTo: engineCard.bottomAnchor, constant: -20),
            engineButton.widthAnchor.constraint(equalToConstant: 150),
            engineButton.heightAnchor.constraint(equalToConstant: 34),

            // Mic test content
            testKicker.leadingAnchor.constraint(equalTo: micTest.leadingAnchor, constant: 20),
            testKicker.topAnchor.constraint(equalTo: micTest.topAnchor, constant: 20),

            waveform.leadingAnchor.constraint(equalTo: testKicker.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: micTest.trailingAnchor, constant: -20),
            waveform.topAnchor.constraint(equalTo: testKicker.bottomAnchor, constant: 12),
            waveform.heightAnchor.constraint(equalToConstant: 58),

            transcript.leadingAnchor.constraint(equalTo: testKicker.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: micTest.trailingAnchor, constant: -20),
            transcript.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 10),
            transcript.heightAnchor.constraint(equalToConstant: 40),

            testStatus.leadingAnchor.constraint(equalTo: testKicker.leadingAnchor),
            testStatus.bottomAnchor.constraint(equalTo: micTest.bottomAnchor, constant: -16),
            testStatus.trailingAnchor.constraint(lessThanOrEqualTo: micTest.trailingAnchor, constant: -20),

            // Ready content
            readyKicker.leadingAnchor.constraint(equalTo: ready.leadingAnchor, constant: 20),
            readyKicker.topAnchor.constraint(equalTo: ready.topAnchor, constant: 20),

            readyTitle.leadingAnchor.constraint(equalTo: readyKicker.leadingAnchor),
            readyTitle.topAnchor.constraint(equalTo: readyKicker.bottomAnchor, constant: 8),

            readyHint.leadingAnchor.constraint(equalTo: readyKicker.leadingAnchor),
            readyHint.trailingAnchor.constraint(lessThanOrEqualTo: startButton.leadingAnchor, constant: -16),
            readyHint.topAnchor.constraint(equalTo: readyTitle.bottomAnchor, constant: 6),

            startButton.trailingAnchor.constraint(equalTo: ready.trailingAnchor, constant: -20),
            startButton.bottomAnchor.constraint(equalTo: ready.bottomAnchor, constant: -20),
            startButton.widthAnchor.constraint(equalToConstant: 170),
            startButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        return window
    }

    private func animateCards() {
        for (index, card) in cards.enumerated() {
            card.alphaValue = 0
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50 * index))
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0.34
                NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 1
                NSAnimationContext.endGrouping()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Granting in System Settings only takes effect after relaunch for
        // screen recording, but refreshing on focus keeps statuses honest.
        refreshPermissions()
        startTestIfPossible()
    }

    func windowWillClose(_ notification: Notification) {
        endTest()
    }
}

/// One permission line: icon, name, live status, and a fix button.
@MainActor
private final class PermissionRow: NSView {
    private let tile = NSView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
    private let button: PillButton
    private var grantHandler: (() -> Void)?

    init(title: String, symbol: String, onGrant: @escaping () -> Void) {
        button = PillButton("Grant", kind: .secondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        grantHandler = onGrant

        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.backgroundColor = ReaderTheme.inset.cgColor

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = ReaderTheme.textSecondary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = title
        nameLabel.font = ReaderTheme.interfaceFont(size: 13, weight: .medium)
        nameLabel.textColor = ReaderTheme.textPrimary

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.attributedStringValue = ReaderTheme.micro("NEEDED", size: 9)

        button.font = ReaderTheme.interfaceFont(size: 11, weight: .semibold)
        button.onPress = { [weak self] in self?.grantHandler?() }

        addSubview(tile)
        tile.addSubview(icon)
        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 30),
            tile.heightAnchor.constraint(equalToConstant: 30),

            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: -15),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 88),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PermissionRow is built in code")
    }

    func update(granted: Bool, denied: Bool) {
        if granted {
            tile.layer?.backgroundColor = ReaderTheme.amber.withAlphaComponent(0.14).cgColor
            icon.contentTintColor = ReaderTheme.amber
            statusLabel.attributedStringValue = ReaderTheme.micro("GRANTED", color: ReaderTheme.amber, size: 9)
            button.title = "Allowed"
            button.isEnabled = false
        } else if denied {
            tile.layer?.backgroundColor = ReaderTheme.danger.withAlphaComponent(0.12).cgColor
            icon.contentTintColor = ReaderTheme.danger
            statusLabel.attributedStringValue = ReaderTheme.micro("MISSING · SEE SETTINGS", color: ReaderTheme.danger, size: 9)
            button.title = "Fix"
            button.isEnabled = true
        } else {
            tile.layer?.backgroundColor = ReaderTheme.inset.cgColor
            icon.contentTintColor = ReaderTheme.textSecondary
            statusLabel.attributedStringValue = ReaderTheme.micro("NEEDED", color: ReaderTheme.textSecondary, size: 9)
            button.title = "Grant"
            button.isEnabled = true
        }
    }
}
