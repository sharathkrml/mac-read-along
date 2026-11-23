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

/// The floating session widget: state, model, stop. Draggable, non-activating,
/// restorable from the menu bar while a session runs.
@MainActor
final class StatusCard {
    private var panel: StatusPanel?
    private let activity = ActivityBars()
    private let stateMicro = Widget.microLabel("PAUSED")
    private let bigLabel = Widget.displayLabel("Paused", size: 24, weight: .light, color: ReaderTheme.textSecondary)
    private let detail = Widget.microLabel("PHONON-2 · ENGLISH", size: 9)
    private let stopButton = PillButton("Stop", kind: .primary)
    private let retryButton = PillButton("Retry", kind: .secondary)

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

        let width: CGFloat = 340
        let height: CGFloat = 104
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
    func update(state: SpeechEngineState, model: String) {
        let modelMicro = "\(model.uppercased()) · ENGLISH"
        switch state {
        case .idle:
            activity.isActive = false
            activity.tint = ReaderTheme.textSecondary
            stateMicro.attributedStringValue = ReaderTheme.micro("PAUSED", color: ReaderTheme.textSecondary)
            bigLabel.stringValue = "Paused"
            bigLabel.textColor = ReaderTheme.textSecondary
            detail.attributedStringValue = ReaderTheme.micro(modelMicro, size: 9)
            retryButton.isHidden = true
        case .starting(let message):
            activity.isActive = true
            activity.tint = ReaderTheme.amber
            stateMicro.attributedStringValue = ReaderTheme.micro("STARTING", color: ReaderTheme.amber)
            bigLabel.stringValue = "Starting"
            bigLabel.textColor = ReaderTheme.textPrimary
            detail.attributedStringValue = ReaderTheme.micro(message, size: 9)
            retryButton.isHidden = true
        case .listening:
            activity.isActive = true
            activity.tint = ReaderTheme.amber
            stateMicro.attributedStringValue = ReaderTheme.micro("FOLLOWING", color: ReaderTheme.amber)
            bigLabel.stringValue = "Listening"
            bigLabel.textColor = ReaderTheme.textPrimary
            detail.attributedStringValue = ReaderTheme.micro(modelMicro, size: 9)
            retryButton.isHidden = true
        case .failed(let message):
            activity.isActive = false
            activity.tint = ReaderTheme.danger
            stateMicro.attributedStringValue = ReaderTheme.micro("ATTENTION", color: ReaderTheme.danger)
            bigLabel.stringValue = "Engine error"
            bigLabel.textColor = ReaderTheme.danger
            detail.attributedStringValue = ReaderTheme.micro(message, size: 9)
            retryButton.isHidden = false
        }
        detail.toolTip = detail.stringValue
    }

    private func makePanel() {
        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 104),
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

        let view = Widget.card(radius: 26)
        view.layer?.shadowOpacity = 0.45
        view.layer?.shadowRadius = 26
        view.layer?.shadowOffset = CGSize(width: 0, height: -10)

        for subview in [activity, stateMicro, bigLabel, detail, stopButton, retryButton] {
            view.addSubview(subview)
        }
        retryButton.isHidden = true

        NSLayoutConstraint.activate([
            activity.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            activity.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            activity.widthAnchor.constraint(equalToConstant: 26),
            activity.heightAnchor.constraint(equalToConstant: 20),

            stateMicro.leadingAnchor.constraint(equalTo: activity.trailingAnchor, constant: 10),
            stateMicro.centerYAnchor.constraint(equalTo: activity.centerYAnchor),

            bigLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            bigLabel.topAnchor.constraint(equalTo: activity.bottomAnchor, constant: 8),
            bigLabel.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -12),

            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            detail.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -12),

            retryButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 64),
            retryButton.heightAnchor.constraint(equalToConstant: 34),

            stopButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stopButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 74),
            stopButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        panel.contentView = view
        self.panel = panel
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
