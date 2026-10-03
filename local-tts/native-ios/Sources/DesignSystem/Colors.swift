import SwiftUI

/// Fixed dark palette for the Import screen and its sheets (matches the
/// supplied mockup) — not theme-adaptive, used deliberately regardless of
/// system light/dark mode.
extension Color {
    static let appBackground = Color(hex: 0x0A0A0A)
    static let appSecondaryBackground = Color(hex: 0x1A1A1A)
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

    // The original-PDF page's own chunk highlight, deliberately NOT a
    // `ReaderTheme` color: that page is paper-white with black type in every
    // theme, while the two above are built for the opposite (light text on a
    // dark ground) — `chunkHighlightBackground` is a near-black navy, which
    // over white paper reads as a muddy grey smear rather than a highlight.
    // Warm amber for the same reason a real highlighter is yellow: it is the
    // only saturated hue light enough to leave black type near its full
    // contrast (~17:1 here), where any grey costs contrast and reads as
    // "dimmed" rather than "marked". Drawn with `.multiply`, so it tints the
    // paper and leaves the type itself untouched — see `ReaderPDFPageView`.
    static let pdfPageHighlight = Color(hex: 0xFFE0A0)

    // ReadingStatsView's contribution graph (and Book Shelf's own small
    // teaser dots — see ImportHomeView.recentActivityDots) — a 5-step
    // intensity ramp (0 = no activity that day) as increasing ink opacity
    // over `BookShelfPalette`'s light background, rather than a hue ramp —
    // reads as dots lighting up, not a GitHub-style color-coded heatmap.
    // Shelf teasers keep this ink ramp; the dark stats graph uses the same
    // opacity levels with appPrimaryText via statsIntensity below.
    static let statsIntensity0 = BookShelfPalette.primaryText.opacity(0.08)
    static let statsIntensity1 = BookShelfPalette.primaryText.opacity(0.32)
    static let statsIntensity2 = BookShelfPalette.primaryText.opacity(0.55)
    static let statsIntensity3 = BookShelfPalette.primaryText.opacity(0.78)
    static let statsIntensity4 = BookShelfPalette.primaryText

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    /// `DayActivity.intensityLevel` (0...4) -> the matching ramp step.
    static func statsIntensity(level: Int, colorScheme: ColorScheme = .light) -> Color {
        if colorScheme == .dark {
            let opacity: Double
            switch level {
            case ...0: opacity = 0.08
            case 1: opacity = 0.32
            case 2: opacity = 0.55
            case 3: opacity = 0.78
            default: opacity = 1
            }
            return .appPrimaryText.opacity(opacity)
        }

        switch level {
        case ...0: return .statsIntensity0
        case 1: return .statsIntensity1
        case 2: return .statsIntensity2
        case 3: return .statsIntensity3
        default: return .statsIntensity4
        }
    }
}

/// Shared dark surface used by full-height presentation chrome. Settings
/// uses a stronger white glow and bottom-weighted grain for its sidebar.
struct TexturedDarkBackground: View {
    enum Variant {
        case neutral
        case sidebar
    }

    var variant: Variant = .neutral

    var body: some View {
        ZStack {
            Color.appBackground

            LinearGradient(
                colors: [
                    Color(hex: 0x252525),
                    Color(hex: 0x151515),
                    Color(hex: 0x080808),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            if variant == .sidebar {
                sidebarLight
            } else {
                RadialGradient(
                    colors: [bottomLight, .clear],
                    center: UnitPoint(x: 0.08, y: 0.86),
                    startRadius: 0,
                    endRadius: 430)

                RadialGradient(
                    colors: [topLight, .clear],
                    center: UnitPoint(x: 0.92, y: 0.08),
                    startRadius: 0,
                    endRadius: 340)

                RadialGradient(
                    colors: [Color.black.opacity(0.78), .clear],
                    center: UnitPoint(x: 0.30, y: 0.48),
                    startRadius: 10,
                    endRadius: 310)
            }

            StaticFilmGrain(
                spacing: variant == .sidebar ? 2 : 2.25,
                intensity: variant == .sidebar ? 1.08 : 1,
                bottomBoost: variant == .sidebar ? 0.55 : 0)
                .blendMode(.softLight)
                .opacity(variant == .sidebar ? 1 : 0.94)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The sidebar's lighting, built as "a dark core with light wrapping its
    /// lower-trailing edge" rather than "glows with a vignette on top".
    ///
    /// The band of light is the *boundary* of the dark shape, so the shape is
    /// what has to be right. An `EllipticalGradient` gives it the panel's own
    /// tall aspect — a `RadialGradient` can only ever darken a circle, which on
    /// a narrow panel leaves light pooling at the top and bottom instead of
    /// sweeping around one continuous edge.
    @ViewBuilder
    private var sidebarLight: some View {
        // Sweeps the bottom edge.
        RadialGradient(
            colors: [Color.white.opacity(0.42), .clear],
            center: UnitPoint(x: 0.50, y: 0.97),
            startRadius: 0,
            endRadius: 470)

        // Carries that sweep up the trailing edge, just off-panel so only its
        // inner falloff shows.
        RadialGradient(
            colors: [Color.white.opacity(0.26), .clear],
            center: UnitPoint(x: 1.04, y: 0.60),
            startRadius: 0,
            endRadius: 360)

        RadialGradient(
            colors: [topLight, .clear],
            center: UnitPoint(x: 0.92, y: 0.08),
            startRadius: 0,
            endRadius: 340)

        EllipticalGradient(
            colors: [
                Color.black.opacity(0.88),
                Color.black.opacity(0.74),
                .clear,
            ],
            center: UnitPoint(x: 0.36, y: 0.44),
            startRadiusFraction: 0,
            endRadiusFraction: 0.66)
    }

    private var topLight: Color {
        switch variant {
        case .neutral: return Color.white.opacity(0.12)
        case .sidebar: return Color.white.opacity(0.10)
        }
    }

    private var bottomLight: Color {
        switch variant {
        case .neutral: return Color.white.opacity(0.22)
        case .sidebar: return Color.white.opacity(0.38)
        }
    }
}

private struct StaticFilmGrain: View {
    let spacing: CGFloat
    let intensity: Double
    let bottomBoost: Double

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let columns = Int(ceil(size.width / spacing))
            let rows = Int(ceil(size.height / spacing))

            for row in 0..<rows {
                for column in 0..<columns {
                    let value = noise(column: column, row: row)
                    let verticalProgress = rows > 1 ? Double(row) / Double(rows - 1) : 0
                    let offsetX = CGFloat(value & 0xff) / 255 * spacing
                    let offsetY = CGFloat((value >> 8) & 0xff) / 255 * spacing
                    let diameter = 0.55 + CGFloat((value >> 16) & 0x3) * 0.18
                    let opacity = min(
                        (0.15 + Double((value >> 20) & 0x7) * 0.018)
                            * intensity * (1 + bottomBoost * verticalProgress),
                        1)
                    let rect = CGRect(
                        x: CGFloat(column) * spacing + offsetX,
                        y: CGFloat(row) * spacing + offsetY,
                        width: diameter,
                        height: diameter)
                    let color = value.isMultiple(of: 3) ? Color.white : Color.black
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                }
            }
        }
    }

    private func noise(column: Int, row: Int) -> UInt64 {
        var value = UInt64(0x6A09E667F3BCC909)
            ^ UInt64(column) &* 73_856_093
            ^ UInt64(row) &* 19_349_663
        value ^= value >> 13
        value &*= 1_274_126_177
        return value ^ (value >> 16)
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
    case warmPaper
    case sepia
    case linen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .carbon: return "Carbon"
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .midnight: return "Midnight"
        case .sage: return "Sage"
        case .warmPaper: return "Warm Paper"
        case .sepia: return "Sepia"
        case .linen: return "Linen"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark, .carbon, .midnight: return .dark
        case .claude, .chatGPT, .sage, .warmPaper, .sepia, .linen: return .light
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
        case .warmPaper: return Color(hex: 0xF7F1E3)
        case .sepia: return Color(hex: 0xF2E2C4)
        case .linen: return Color(hex: 0xF8F4EC)
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
        case .warmPaper: return Color(hex: 0x2D2923)
        case .sepia: return Color(hex: 0x30271D)
        case .linen: return Color(hex: 0x26231F)
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
        case .warmPaper: return Color(hex: 0x655E54)
        case .sepia: return Color(hex: 0x695744)
        case .linen: return Color(hex: 0x625D54)
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
        case .warmPaper: return Color(hex: 0xE8DECA).opacity(0.94)
        case .sepia: return Color(hex: 0xE2CBA4).opacity(0.94)
        case .linen: return Color(hex: 0xEAE3D8).opacity(0.94)
        }
    }

    var controlAccent: Color {
        switch self {
        case .dark, .carbon: return .green
        case .claude, .chatGPT, .midnight, .sage, .warmPaper, .sepia, .linen:
            return wordHighlightBackground
        }
    }

    /// Selection outlines and icons inside the reader options sheet. Dark
    /// and Carbon deliberately use white here while their native toggles
    /// keep the familiar green `controlAccent` tint.
    var optionsAccent: Color {
        switch self {
        case .dark, .carbon: return .white
        case .claude, .chatGPT, .midnight, .sage, .warmPaper, .sepia, .linen:
            return controlAccent
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
        case .warmPaper: return Color(hex: 0xE8D8B8)
        case .sepia: return Color(hex: 0xE5CAA0)
        case .linen: return Color(hex: 0xE5DDD0)
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
        case .warmPaper: return Color(hex: 0x7B4F32)
        case .sepia: return Color(hex: 0x814E28)
        case .linen: return Color(hex: 0x62574B)
        }
    }

    var highlightedText: Color {
        switch self {
        case .dark, .carbon, .chatGPT, .midnight, .sage, .linen: return .white
        case .claude: return Color(hex: 0x141413)
        case .warmPaper: return Color(hex: 0xFFFAF0)
        case .sepia: return Color(hex: 0xFFF6E5)
        }
    }
}

extension LinearGradient {
    /// Deterministic placeholder gradient keyed off a stable string seed
    /// (a book id) — the same seed always yields the same colors, so a
    /// placeholder shown while real artwork loads doesn't flicker to a
    /// different color on every redraw. Voice cover art uses `OrbCoverArt`
    /// instead; this remains for saved projects without a rendered cover.
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
