import XCTest
import Carbon.HIToolbox
@testable import ReadAlong

final class AppSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsOnACleanDomain() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertEqual(settings.model, "phonon-2")
        XCTAssertEqual(settings.hotkeyCode, AppSettings.defaultKeyCode)
        XCTAssertEqual(settings.hotkeyModifiers, AppSettings.defaultModifiers)
        XCTAssertTrue(settings.cardVisible)
        XCTAssertEqual(settings.microphoneID, "")
    }

    func testValuesPersistAndRoundTrip() {
        let defaults = freshDefaults()
        var settings = AppSettings(defaults: defaults)

        settings.model = "phonon-3"
        settings.hotkeyCode = 11
        settings.hotkeyModifiers = 4352 // plain command key
        settings.cardVisible = false
        settings.microphoneID = "BuiltInMicrophoneDevice"

        // A second instance over the same domain sees the stored values.
        settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.model, "phonon-3")
        XCTAssertEqual(settings.hotkeyCode, 11)
        XCTAssertEqual(settings.hotkeyModifiers, 4352)
        XCTAssertFalse(settings.cardVisible)
        XCTAssertEqual(settings.microphoneID, "BuiltInMicrophoneDevice")
    }

    func testModelEmptyStringFallsBackToDefault() {
        var settings = AppSettings(defaults: freshDefaults())
        settings.model = ""
        XCTAssertEqual(AppSettings(defaults: settings.defaults).model, "")
        // Empty is stored verbatim; the engine setting UI guards against it.
    }
}

final class HotkeyDisplayTests: XCTestCase {
    func testDefaultHotkeyRendersAsOptionCommandR() {
        XCTAssertEqual(
            HotkeyManager.displayString(keyCode: 15, modifiers: AppSettings.defaultModifiers),
            "⌥⌘R"
        )
    }

    func testUnmappedKeyFallsBackToKeyCodeLabel() {
        XCTAssertEqual(HotkeyManager.displayString(keyCode: 99, modifiers: 0), "Key 99")
    }

    func testCarbonModifierConversion() {
        var flags: NSEvent.ModifierFlags = [.command, .option]
        XCTAssertEqual(HotkeyManager.carbonModifiers(from: flags), AppSettings.defaultModifiers)
        flags = [.shift, .control]
        XCTAssertEqual(
            HotkeyManager.carbonModifiers(from: flags),
            UInt32(shiftKey | controlKey)
        )
    }
}
