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

    // Type
    static let textPrimary = NSColor(hex: 0xF3F1EC)
    static let textSecondary = NSColor(hex: 0x8C919B)
    static let textTertiary = NSColor(hex: 0x5A5F68)

    // Accent
    static let amber = NSColor(hex: 0xF5A93B)
    static let amberSoft = NSColor(hex: 0xFFD28A)
    /// Amber dark enough to read on white paper.
    static let amberDeep = NSColor(hex: 0xB5730E)
    static let inkOnAmber = NSColor(hex: 0x1A1206)

    // Data accents
    static let danger = NSColor(hex: 0xE07A7A)

    // Fonts
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
