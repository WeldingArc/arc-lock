// The five looks (Settings › Appearance). The choice lives in the App Group so the block screen and the usage line
// match the app. tools/make_phone_icon.swift draws the app icons and block-screen marks in the same colors.
import Foundation

enum ArcTheme: String, CaseIterable, Identifiable, Sendable {
    case navy, graphite, forest, plum, paper

    static let key = "theme"
    var id: String { rawValue }

    /// The chosen theme (Navy & Brass until one is picked).
    static var current: ArcTheme {
        get { AppGroup.defaults.string(forKey: key).flatMap(ArcTheme.init(rawValue:)) ?? .navy }
        set { AppGroup.defaults.set(newValue.rawValue, forKey: key) }
    }

    var name: String {
        switch self {
        case .navy: String(localized: "Navy")
        case .graphite: String(localized: "Graphite")
        case .forest: String(localized: "Forest")
        case .plum: String(localized: "Plum")
        case .paper: String(localized: "Paper")
        }
    }

    var isLight: Bool { self == .paper }

    /// The app icon that matches (nil = the primary icon).
    var iconName: String? { self == .navy ? nil : "AppIcon-\(rawValue.capitalized)" }

    var colors: ThemeColors {
        switch self {
        case .navy:
            ThemeColors(night: 0x0E1424, deep: 0x0A0F1C, card: 0x151D31, cardHi: 0x1B2540, ink: 0xE9E6DF, muted: 0x9AA1B1,
                        faint: 0x6B7385, accent: 0xC8A96A, accentLight: 0xE9CD92, accentDark: 0x967A46, sage: 0x8FB3A0, rose: 0xD49A8C)
        case .graphite:
            ThemeColors(night: 0x111214, deep: 0x0B0C0D, card: 0x1A1C1F, cardHi: 0x222529, ink: 0xEDEDEB, muted: 0xA3A6AB,
                        faint: 0x6E7278, accent: 0xC9CDD3, accentLight: 0xF2F4F7, accentDark: 0x8D939B, sage: 0x9DB8A8, rose: 0xD6A097)
        case .forest:
            ThemeColors(night: 0x0D1813, deep: 0x08110C, card: 0x14241C, cardHi: 0x1B2F25, ink: 0xE7ECE4, muted: 0x9EAEA3,
                        faint: 0x68786D, accent: 0xA8CBA0, accentLight: 0xD3E8C9, accentDark: 0x6F9468, sage: 0x9FC3B5, rose: 0xD9A08F)
        case .plum:
            ThemeColors(night: 0x170F1C, deep: 0x100A14, card: 0x21162A, cardHi: 0x2A1D35, ink: 0xEFE6EA, muted: 0xAE9FB0,
                        faint: 0x76687A, accent: 0xE0A9A0, accentLight: 0xF4CFC8, accentDark: 0xA9726B, sage: 0x9FBFAE, rose: 0xE88C84)
        case .paper:
            ThemeColors(night: 0xF4F1EA, deep: 0xEAE6DC, card: 0xFFFFFF, cardHi: 0xFBF8F1, ink: 0x1E2433, muted: 0x5E6573,
                        faint: 0x8C919B, accent: 0x2F4A7A, accentLight: 0x4D6799, accentDark: 0x1D2F52, sage: 0x4F8A6E, rose: 0xB5594A)
        }
    }
}

/// 0xRRGGBB values; `night` is the background, `accent` the buttons and highlights, `sage` progress, `rose` warnings.
struct ThemeColors: Sendable {
    let night, deep, card, cardHi, ink, muted, faint, accent, accentLight, accentDark, sage, rose: UInt32
}
