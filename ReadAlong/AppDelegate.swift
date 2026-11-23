import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One engine, one stream: the reader window and sessions share it.
    private let engine = SpeechEngine()
    private let session: SessionController
    private let reader: ReaderController
    private let settings = SettingsController()
    private let onboarding: OnboardingController
    private var hotkey: HotkeyManager?
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var cardItem: NSMenuItem!

    override init() {
        session = SessionController(engine: engine)
        reader = ReaderController(engine: engine)
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
        let openItem = NSMenuItem(
            title: "Open Reading…",
            action: #selector(openReading),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

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

        session.onStateChange = { [weak self] in self?.refreshMenu() }

        hotkey = HotkeyManager { [weak self] in self?.session.toggle() }
        let hotkeyStatus = hotkey?.register() ?? -1
        Log.note("hotkey register status: \(hotkeyStatus)")

        // Permissions are re-checked on every launch: a revoked grant gets
        // the onboarding fix path instead of a silently broken app.
        let micGranted = Permissions.microphoneGranted()
        let screenGranted = Permissions.screenRecordingGranted()
        if !AppSettings.standard.onboardingCompleted || !micGranted || !screenGranted {
            Log.note("onboarding shown: completed=\(AppSettings.standard.onboardingCompleted) mic=\(micGranted) screen=\(screenGranted)")
            onboarding.show()
        }

        installShortcutMonitor()
    }

    /// Standard app shortcuts while any Read Along window is frontmost.
    private func installShortcutMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case ",":
                MainActor.assumeIsolated { self?.showSettings() }
                return nil
            case "o":
                MainActor.assumeIsolated { self?.openReading() }
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
        reader.shutdown()
        hotkey?.unregister()
    }

    @objc private func openReading() {
        reader.openDocumentPanel()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        reader.open(url: url)
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
