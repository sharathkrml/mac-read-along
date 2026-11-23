import AppKit

/// Widget-wall design language taken from the reference video: near-black
/// cards floating on a graphite canvas, huge thin numerals, uppercase micro
/// labels, one amber accent.
enum ReaderTheme {
    // Canvas
    static let canvas = NSColor(hex: 0x17181B)
    static let canvasTop = NSColor(hex: 0x232428)
    static let canvasBottom = NSColor(hex: 0x0F1012)

    // Cards and surfaces
    static let card = NSColor(hex: 0x0B0C0E)
    static let cardRaised = NSColor(hex: 0x15161A)
    static let inset = NSColor(hex: 0x1E1F24)
    static let hairline = NSColor.white.withAlphaComponent(0.07)
    static let surface = cardRaised
    static let surfaceRaised = cardRaised

    // Type
    static let textPrimary = NSColor(hex: 0xF3F1EC)
    static let textSecondary = NSColor(hex: 0x8C919B)
    static let textTertiary = NSColor(hex: 0x5A5F68)

    // Accent
    static let amber = NSColor(hex: 0xF5A93B)
    static let amberSoft = NSColor(hex: 0xFFD28A)
    static let inkOnAmber = NSColor(hex: 0x1A1206)
    static let readingFill = NSColor(hex: 0x4A3514).withAlphaComponent(0.9)
    static let readingInk = NSColor(hex: 0xFFE2A6)
    static let readingStroke = NSColor(hex: 0xF5B44A)
    static let nextFill = NSColor(hex: 0xF5A93B).withAlphaComponent(0.10)

    // Data accents
    static let danger = NSColor(hex: 0xE07A7A)
    static let blue = NSColor(hex: 0x5A9CFF)
    static let green = NSColor(hex: 0x54D6A0)
    static let pink = NSColor(hex: 0xEF6F9A)
    static let purple = NSColor(hex: 0x9B7BF7)
    static let yellow = NSColor(hex: 0xF7C948)

    // Fonts
    static func readingFont(size: CGFloat = 20) -> NSFont {
        NSFont(name: "NewYork-Regular", size: size)
            ?? NSFont(name: "New York", size: size)
            ?? NSFont(name: "Iowan Old Style", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    static func interfaceFont(size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func display(size: CGFloat, weight: NSFont.Weight = .thin) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func micro(_ text: String, color: NSColor = textSecondary, size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color,
                .kern: 1.2,
            ]
        )
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
