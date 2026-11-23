import AppKit

/// Paper & Ink dark palette from the project's UI direction: graphite surfaces,
/// warm light ink, one amber reading marker.
enum ReaderTheme {
    static let canvas = NSColor(hex: 0x15171A)
    static let surface = NSColor(hex: 0x1D2024)
    static let surfaceRaised = NSColor(hex: 0x272B31)
    static let textPrimary = NSColor(hex: 0xF1F0EB)
    static let textSecondary = NSColor(hex: 0xA6ADB7)
    static let readingFill = NSColor(hex: 0x554322)
    static let readingInk = NSColor(hex: 0xFFE4A4)
    static let readingStroke = NSColor(hex: 0xE8B95B)
    static let nextFill = NSColor(hex: 0xE8B95B).withAlphaComponent(0.12)
    static let danger = NSColor(hex: 0xD98A8A)

    static func readingFont(size: CGFloat = 19) -> NSFont {
        NSFont(name: "New York", size: size)
            ?? NSFont(name: "Iowan Old Style", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    static func interfaceFont(size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
