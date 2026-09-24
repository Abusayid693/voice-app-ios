import SwiftUI

/// Fixed dark palette for the Import screen and its sheets (matches the
/// supplied mockup) — not theme-adaptive, used deliberately regardless of
/// system light/dark mode.
extension Color {
    static let appBackground = Color(hex: 0x111111)
    static let appSecondaryBackground = Color(hex: 0x222222)
    static let appPrimaryText = Color(hex: 0xEEEEEE)
    static let appSecondaryText = Color(hex: 0x949599)
    static let appTertiaryText = Color(hex: 0x6E6E6E)
    // Deliberately its own value, not derived from appTertiaryText — the
    // finest metadata tier (timestamps, file sizes) reads as its own
    // color, not just a dimmer tertiary.
    static let appMetaText = Color(hex: 0x5F5F5F)

    /// Warm-neutral paper surface for the dedicated Book Shelf reading mode.
    static let whitePaper = Color(hex: 0xF6F6F6)

    // Filled CTA — light background, near-black label.
    static let primaryButtonBackground = Color(hex: 0xEEEEEE)
    static let primaryButtonText = Color(hex: 0x111111)
    // Filled secondary CTA — a lighter, warm-grey fill than
    // appSecondaryBackground, so it still reads as a distinct control.
    static let secondaryButtonBackground = Color(hex: 0x393332)
    static let secondaryButtonText = Color(hex: 0xF7F0EB)
    // Ghost/liquid-glass CTA has no fill color of its own (see
    // ButtonStyles.swift's .ghost — .ultraThinMaterial instead); only its
    // label color lives here.
    static let ghostButtonText = Color(hex: 0xFAF7F7)

    // The "Free Demo"/"OPEN SOURCE" pill treatment — deliberately its own
    // pair, not primaryButtonBackground/Text, so a highlight badge doesn't
    // silently follow the CTA colors if those ever change again.
    static let highlightBadgeBackground = Color(hex: 0xF6F6F6)
    static let highlightBadgeText = Color(hex: 0x000000)

    // ChapterPlayerView's read-along: the currently-playing paragraph's
    // background box, and the currently-playing word's own highlight pill
    // within it — two different colors/scopes, not one reused at two
    // opacities, so each can be tuned independently.
    static let chunkHighlightBackground = Color(hex: 0x0E2439)
    static let wordHighlightBackground = Color(hex: 0x1F5182)

    // ReadingStatsView's contribution graph — a 5-step intensity ramp
    // (0 = no activity that day) in the same blue family as the read-
    // along's own chunk/word highlight pair above, for visual consistency
    // with this app's other "listening activity" indicator rather than
    // borrowing GitHub's green convention.
    static let statsIntensity0 = Color(hex: 0x1A1A1A)
    static let statsIntensity1 = Color(hex: 0x123049)
    static let statsIntensity2 = Color(hex: 0x1A4A73)
    static let statsIntensity3 = Color(hex: 0x1F6BA8)
    static let statsIntensity4 = Color(hex: 0x3D9EF0)

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    /// `DayActivity.intensityLevel` (0...4) -> the matching ramp step.
    static func statsIntensity(level: Int) -> Color {
        switch level {
        case ...0: return .statsIntensity0
        case 1: return .statsIntensity1
        case 2: return .statsIntensity2
        case 3: return .statsIntensity3
        default: return .statsIntensity4
        }
    }
}

/// Presentation values for the app-wide Home modes. Keeping these in the
/// design system leaves `HomeMode` as persistable, UI-independent data.
extension HomeMode {
    var background: Color {
        switch self {
        case .studio: .appBackground
        case .reading: .whitePaper
        }
    }

    var primaryText: Color {
        switch self {
        case .studio: .appPrimaryText
        case .reading: Color(hex: 0x171715)
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .studio: .dark
        case .reading: .light
        }
    }
}

/// Persistable color themes for long-form reading surfaces. Each theme owns
/// the complete reader palette so highlights and floating controls remain
/// legible when moving between dark and light designs.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case dark
    case carbon
    case claude
    case chatGPT
    case midnight
    case sage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .carbon: return "Carbon"
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .midnight: return "Midnight"
        case .sage: return "Sage"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark, .carbon, .midnight: return .dark
        case .claude, .chatGPT, .sage: return .light
        }
    }

    var background: Color {
        switch self {
        case .dark: return .black
        case .carbon: return .appBackground
        case .claude: return Color(hex: 0xF0EEE6)
        case .chatGPT: return .white
        case .midnight: return Color(hex: 0x101525)
        case .sage: return Color(hex: 0xEEF2E8)
        }
    }

    var primaryText: Color {
        switch self {
        case .dark: return .white
        case .carbon: return .appPrimaryText
        case .claude: return Color(hex: 0x141413)
        case .chatGPT: return Color(hex: 0x0D0D0D)
        case .midnight: return Color(hex: 0xEEF0FF)
        case .sage: return Color(hex: 0x253128)
        }
    }

    var secondaryText: Color {
        switch self {
        case .dark: return .white.opacity(0.72)
        case .carbon: return .appMetaText
        case .claude: return Color(hex: 0x6B6A65)
        case .chatGPT: return Color(hex: 0x5D5D5D)
        case .midnight: return Color(hex: 0x9CA6C8)
        case .sage: return Color(hex: 0x687468)
        }
    }

    var controlBackground: Color {
        switch self {
        case .dark: return .white.opacity(0.10)
        case .carbon: return .appSecondaryBackground.opacity(0.92)
        case .claude: return Color(hex: 0xE8E6DC).opacity(0.94)
        case .chatGPT: return Color(hex: 0xF4F4F4).opacity(0.94)
        case .midnight: return Color(hex: 0x1C2440).opacity(0.94)
        case .sage: return Color(hex: 0xDDE5D5).opacity(0.94)
        }
    }

    var controlAccent: Color {
        switch self {
        case .dark, .carbon: return .green
        case .claude, .chatGPT, .midnight, .sage: return wordHighlightBackground
        }
    }

    /// Selection outlines and icons inside the reader options sheet. Dark
    /// and Carbon deliberately use white here while their native toggles
    /// keep the familiar green `controlAccent` tint.
    var optionsAccent: Color {
        switch self {
        case .dark, .carbon: return .white
        case .claude, .chatGPT, .midnight, .sage: return controlAccent
        }
    }

    var chunkHighlightBackground: Color {
        switch self {
        case .dark: return Color(hex: 0x182B3D)
        case .carbon: return .chunkHighlightBackground
        case .claude: return Color(hex: 0xF3DDD3)
        case .chatGPT: return Color(hex: 0xE5F2FF)
        case .midnight: return Color(hex: 0x242A4C)
        case .sage: return Color(hex: 0xD8E4CF)
        }
    }

    var wordHighlightBackground: Color {
        switch self {
        case .dark: return Color(hex: 0x28669E)
        case .carbon: return .wordHighlightBackground
        case .claude: return Color(hex: 0xD97757)
        case .chatGPT: return Color(hex: 0x0285FF)
        case .midnight: return Color(hex: 0x6858C9)
        case .sage: return Color(hex: 0x55705A)
        }
    }

    var highlightedText: Color {
        switch self {
        case .dark, .carbon, .chatGPT, .midnight, .sage: return .white
        case .claude: return Color(hex: 0x141413)
        }
    }
}

extension LinearGradient {
    /// Deterministic placeholder gradient keyed off a stable string seed
    /// (a book id) — the same seed always yields the same colors, so a
    /// placeholder shown while real artwork loads doesn't flicker to a
    /// different color on every redraw. Voice cover art uses `OrbCoverArt`
    /// instead (`DesignSystem/OrbCoverArt.swift`); this remains for
    /// `OpenLibraryBookCard`'s book covers, which have no orb equivalent.
    static func stablePlaceholder(seed: String) -> LinearGradient {
        let pairs: [[Color]] = [
            [.pink, .purple], [.blue, .teal], [.orange, .red],
            [.green, .mint], [.indigo, .cyan], [.yellow, .orange],
        ]
        let sum = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let pair = pairs[sum % pairs.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
