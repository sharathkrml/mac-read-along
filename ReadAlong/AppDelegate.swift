import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let session = SessionController()
    private let reader = ReaderController()
    private var hotkey: HotkeyManager?
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!

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
            keyEquivalent: "r"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Read Along",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        session.onStateChange = { [weak self] in self?.refreshMenu() }

        hotkey = HotkeyManager { [weak self] in self?.session.toggle() }
        let hotkeyStatus = hotkey?.register() ?? -1
        Log.note("hotkey register status: \(hotkeyStatus)")
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

    private func refreshMenu() {
        switch session.state {
        case .idle:
            toggleItem.title = "Start Session"
        case .picking:
            toggleItem.title = "Cancel Picking"
        case .active:
            toggleItem.title = "End Session"
        }
    }
}
