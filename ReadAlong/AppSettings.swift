import Foundation
import Carbon.HIToolbox

/// UserDefaults-backed settings, the single source for every consumer.
/// Injectable defaults keep it testable; a class so the shared instance is
/// mutable through a constant reference.
final class AppSettings {
    @MainActor static let standard = AppSettings(defaults: .standard)

    static let defaultModel = "phonon-2"
    static let defaultKeyCode = UInt32(kVK_ANSI_R)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var model: String {
        get { defaults.string(forKey: Keys.model) ?? Self.defaultModel }
        set { defaults.set(newValue, forKey: Keys.model) }
    }

    var hotkeyCode: UInt32 {
        get {
            (defaults.object(forKey: Keys.hotkeyCode) as? Int)
                .map(UInt32.init) ?? Self.defaultKeyCode
        }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyCode) }
    }

    var hotkeyModifiers: UInt32 {
        get {
            (defaults.object(forKey: Keys.hotkeyModifiers) as? Int)
                .map(UInt32.init) ?? Self.defaultModifiers
        }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyModifiers) }
    }

    var cardVisible: Bool {
        get { defaults.object(forKey: Keys.cardVisible) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.cardVisible) }
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    private enum Keys {
        static let model = "settings.model"
        static let hotkeyCode = "settings.hotkeyCode"
        static let hotkeyModifiers = "settings.hotkeyModifiers"
        static let cardVisible = "settings.cardVisible"
        static let onboardingCompleted = "settings.onboardingCompleted"
    }
}
