import AppKit
import Dispatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keeps the signal sources alive for the app's lifetime.
    private var terminationSources: [DispatchSourceSignal] = []

    /// One engine, one stream: the launcher and read-along sessions share it.
    private let engine = SpeechEngine()
    private let session: SessionController
    private let settings = SettingsController()
    private let onboarding: OnboardingController
    private var hotkey: HotkeyManager?
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var cardItem: NSMenuItem!
    /// True while the launcher sent the user into the window picker.
    private var launcherFlow = false

    override init() {
        session = SessionController(engine: engine)
        onboarding = OnboardingController(engine: engine)
        super.init()

        settings.onModelChange = { [weak self] in self?.engine.applyModelChange() }
        settings.onHotkeyChange = { [weak self] keyCode, modifiers in
            _ = self?.hotkey?.reregister(keyCode: keyCode, modifiers: modifiers)
        }
        settings.onCardVisibilityChange = { [weak self] in
            self?.session.syncStatusCardVisibility()
            self?.refreshMenu()
        }
        settings.onMicrophoneChange = { [weak self] in self?.engine.applyMicrophoneChange() }

        onboarding.onStartReading = { [weak self] in
            guard let self else { return }
            self.launcherFlow = true
            self.session.begin()
        }

        session.onStateChange = { [weak self] in self?.sessionStateChanged() }
    }

    private func sessionStateChanged() {
        refreshMenu()
        switch session.state {
        case .picking:
            onboarding.hide()
        case .active:
            launcherFlow = false
        case .idle:
            // Choosing was cancelled: bring the launcher back.
            if launcherFlow {
                launcherFlow = false
                onboarding.show()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.note("launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "text.alignleft",
                accessibilityDescription: "Read Along"
            )
            button.toolTip = "Read Along"
        }
        Log.note("status item created: \(self.statusItem.button?.image != nil ? "with icon" : "no icon")")

        let menu = NSMenu()
        toggleItem = NSMenuItem(
            title: "Start Session",
            action: #selector(toggleSession),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let onboardingItem = NSMenuItem(
            title: "Show Onboarding…",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        cardItem = NSMenuItem(
            title: "Hide Status Card",
            action: #selector(toggleCard),
            keyEquivalent: ""
        )
        cardItem.target = self
        menu.addItem(cardItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Read Along",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Submenu targets for the static items above.
        menu.items.forEach { item in
            if item.action == #selector(showOnboarding) {
                item.target = self
            }
        }
        statusItem.menu = menu

        hotkey = HotkeyManager { [weak self] in self?.session.toggle() }
        let hotkeyStatus = hotkey?.register() ?? -1
        Log.note("hotkey register status: \(hotkeyStatus)")

        // The launcher is the app's front door: it shows permissions, warms the
        // engine, and sends the reader straight into picking a window.
        onboarding.show()

        installShortcutMonitor()
        installTerminationHandlers()
    }

    /// `pkill` (and a logout) sends SIGTERM, which skips
    /// `applicationWillTerminate` and leaves the speech engine running. Route
    /// it through the normal termination path so `engine.shutdown()` runs.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSources.append(source)
        }
    }

    /// Standard app shortcuts while any Read Along window is frontmost.
    private func installShortcutMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case ",":
                MainActor.assumeIsolated { self?.showSettings() }
                return nil
            case "w":
                MainActor.assumeIsolated { NSApp.keyWindow?.performClose(nil) }
                return nil
            default:
                return event
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.end()
        engine.shutdown()
        hotkey?.unregister()
    }

    @objc private func toggleSession() {
        session.toggle()
    }

    @objc private func showOnboarding() {
        onboarding.show()
    }

    @objc private func showSettings() {
        settings.show()
    }

    @objc private func toggleCard() {
        AppSettings.standard.cardVisible.toggle()
        session.syncStatusCardVisibility()
        refreshMenu()
    }

    private func refreshMenu() {
        switch session.state {
        case .idle:
            toggleItem.title = "Start Session"
        case .picking:
            toggleItem.title = "Cancel Picking"
        case .active:
            toggleItem.title = "End Session"
        }
        cardItem.title = AppSettings.standard.cardVisible ? "Hide Status Card" : "Show Status Card"
    }
}
