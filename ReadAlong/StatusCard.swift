import AppKit
import AVFoundation
import ApplicationServices

/// Where the fix for a missing permission lives, so every surface deep-links
/// to the same place.
enum Permissions {
    @MainActor
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @MainActor
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    static func openMicrophonePane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openScreenRecordingPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// The floating session card: state, model, stop. Draggable, non-activating,
/// restorable from the menu bar while a session runs.
@MainActor
final class StatusCard {
    private var panel: StatusPanel?
    private let dot = StatusDot()
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let modelLabel = NSTextField(labelWithString: "")
    private let stopButton = CallbackButton(title: "Stop")
    private let retryButton = CallbackButton(title: "Retry")

    var onStop: (() -> Void)? {
        didSet { stopButton.onPress = onStop }
    }
    var onRetry: (() -> Void)? {
        didSet { retryButton.onPress = onRetry }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show(near frame: CGRect) {
        if panel == nil {
            makePanel()
        }
        guard let panel else { return }

        let width: CGFloat = 300
        let height: CGFloat = 58
        let x = max(frame.minX + 16, frame.maxX - width - 24)
        let y = max(frame.minY + 16, frame.maxY - height - 48)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The card mirrors engine state; failures offer retry, idle means paused.
    func update(state: SpeechEngineState, model: String) {
        modelLabel.stringValue = model
        switch state {
        case .idle:
            dot.color = ReaderTheme.textSecondary
            statusLabel.stringValue = "Paused"
            retryButton.isHidden = true
        case .starting(let message):
            dot.color = ReaderTheme.textSecondary
            statusLabel.stringValue = message
            retryButton.isHidden = true
        case .listening:
            dot.color = ReaderTheme.readingStroke
            statusLabel.stringValue = "Listening — read aloud"
            retryButton.isHidden = true
        case .failed(let message):
            dot.color = ReaderTheme.danger
            statusLabel.stringValue = message
            retryButton.isHidden = false
        }
        statusLabel.toolTip = statusLabel.stringValue
    }

    private func makePanel() {
        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 58),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ReaderTheme.surfaceRaised.cgColor
        view.layer?.cornerRadius = 14
        view.layer?.borderColor = ReaderTheme.readingStroke.withAlphaComponent(0.16).cgColor
        view.layer?.borderWidth = 1
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.35
        view.layer?.shadowRadius = 16
        view.layer?.shadowOffset = CGSize(width: 0, height: -5)

        dot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = ReaderTheme.interfaceFont(size: 12, weight: .medium)
        statusLabel.textColor = ReaderTheme.textPrimary
        statusLabel.lineBreakMode = .byTruncatingTail
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.font = ReaderTheme.interfaceFont(size: 11)
        modelLabel.textColor = ReaderTheme.textSecondary

        for button in [stopButton, retryButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = ReaderTheme.readingStroke.cgColor
            button.layer?.cornerRadius = 8
            button.font = ReaderTheme.interfaceFont(size: 12, weight: .semibold)
            button.contentTintColor = ReaderTheme.canvas
            button.setButtonType(.momentaryPushIn)
        }
        retryButton.isHidden = true

        view.addSubview(dot)
        view.addSubview(statusLabel)
        view.addSubview(modelLabel)
        view.addSubview(stopButton)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -10),

            modelLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            modelLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -13),
            modelLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -10),

            stopButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 66),
            stopButton.heightAnchor.constraint(equalToConstant: 32),

            retryButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 62),
            retryButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        panel.contentView = view
        self.panel = panel
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small state dot that can live outside any window's layer tree.
@MainActor
private final class StatusDot: NSView {
    var color: NSColor = ReaderTheme.textSecondary {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
}

/// Borderless-styled buttons that fire a callback.
@MainActor
private final class CallbackButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("CallbackButton is built in code")
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}
