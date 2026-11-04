import SwiftUI

/// Semantic theme resolved from the backend appearance tokens, with a built-in fallback.
struct PawlyTheme {
    var background: Color
    var surface: Color
    var surfaceAlt: Color
    var ink: Color
    var muted: Color
    var primary: Color
    var primarySoft: Color
    var accent: Color
    var accentSoft: Color
    var border: Color
    var danger: Color
    var success: Color
    var cardRadius: CGFloat
    var controlRadius: CGFloat
    var isDark: Bool

    static let displayDesign: Font.Design = .serif

    init(background: Color, surface: Color, surfaceAlt: Color, ink: Color, muted: Color,
         primary: Color, primarySoft: Color, accent: Color, accentSoft: Color,
         border: Color, danger: Color, success: Color,
         cardRadius: CGFloat = 24, controlRadius: CGFloat = 16, isDark: Bool = false) {
        self.background = background
        self.surface = surface
        self.surfaceAlt = surfaceAlt
        self.ink = ink
        self.muted = muted
        self.primary = primary
        self.primarySoft = primarySoft
        self.accent = accent
        self.accentSoft = accentSoft
        self.border = border
        self.danger = danger
        self.success = success
        self.cardRadius = cardRadius
        self.controlRadius = controlRadius
        self.isDark = isDark
    }

    static let fallbackLight = PawlyTheme(
        background: Color.hex( "#FBF6EE"),
        surface: Color.hex( "#FFFFFF"),
        surfaceAlt: Color.hex( "#F4EADC"),
        ink: Color.hex( "#241F1A"),
        muted: Color.hex( "#7B6F63"),
        primary: Color.hex( "#F26B3A"),
        primarySoft: Color.hex( "#FFE3D6"),
        accent: Color.hex( "#7FA96A"),
        accentSoft: Color.hex( "#E4EFD9"),
        border: Color.hex( "#EADFD2"),
        danger: Color.hex( "#C44536"),
        success: Color.hex( "#4F8A5B")
    )

    static let fallbackDark = PawlyTheme(
        background: Color.hex( "#171411"),
        surface: Color.hex( "#221D19"),
        surfaceAlt: Color.hex( "#2C251F"),
        ink: Color.hex( "#F5EDE3"),
        muted: Color.hex( "#A79B8E"),
        primary: Color.hex( "#FF7F4D"),
        primarySoft: Color.hex( "#4A2A1D"),
        accent: Color.hex( "#9CC287"),
        accentSoft: Color.hex( "#2E3A26"),
        border: Color.hex( "#3A3029"),
        danger: Color.hex( "#E2705F"),
        success: Color.hex( "#7FB98B"),
        isDark: true
    )

    init(appearance: AppearancePayload?, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        let fallback = isDark ? PawlyTheme.fallbackDark : PawlyTheme.fallbackLight
        guard let tokens = appearance?.tokens else {
            self = fallback
            return
        }
        func token(_ key: String) -> String? {
            let darkKey = isDark ? "\(key).dark" : key
            if let value = tokens[darkKey]?.stringValue, !value.isEmpty { return value }
            if isDark, let value = tokens[key]?.stringValue, !value.isEmpty { return value }
            return nil
        }
        func color(_ key: String, fallback fallbackColor: Color) -> Color {
            guard let raw = token(key) else { return fallbackColor }
            return Color(hex: raw) ?? fallbackColor
        }
        func number(_ key: String, fallback fallbackValue: CGFloat) -> CGFloat {
            guard let raw = token(key), let value = Double(raw) else { return fallbackValue }
            return CGFloat(value)
        }
        self.init(
            background: color("color.background", fallback: fallback.background),
            surface: color("color.surface", fallback: fallback.surface),
            surfaceAlt: color("color.surface_alt", fallback: fallback.surfaceAlt),
            ink: color("color.ink", fallback: fallback.ink),
            muted: color("color.muted", fallback: fallback.muted),
            primary: color("color.primary", fallback: fallback.primary),
            primarySoft: color("color.primary_soft", fallback: fallback.primarySoft),
            accent: color("color.accent", fallback: fallback.accent),
            accentSoft: color("color.accent_soft", fallback: fallback.accentSoft),
            border: color("color.border", fallback: fallback.border),
            danger: color("color.danger", fallback: fallback.danger),
            success: color("color.success", fallback: fallback.success),
            cardRadius: number("radius.card", fallback: fallback.cardRadius),
            controlRadius: number("radius.control", fallback: fallback.controlRadius),
            isDark: isDark
        )
    }

    var cardShadow: Color { isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.06) }
}

extension Color {
    /// Non-failable hex helper for built-in fallback palettes.
    static func hex(_ hex: String) -> Color {
        Color(hex: hex) ?? .clear
    }

    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        guard let value = UInt64(cleaned, radix: 16) else { return nil }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        } else {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

private struct PawlyThemeKey: EnvironmentKey {
    static let defaultValue: PawlyTheme = .fallbackLight
}

extension EnvironmentValues {
    var pawly: PawlyTheme {
        get { self[PawlyThemeKey.self] }
        set { self[PawlyThemeKey.self] = newValue }
    }
}
