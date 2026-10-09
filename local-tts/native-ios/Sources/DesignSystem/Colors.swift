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

    // Flat icon-and-label tab navigation with a coral selection and soft
    // blue-gray inactive items on paper/charcoal surfaces.
    static let tabSelected = Color(hex: 0xFF5A5F)
    static let tabInactiveLight = Color(hex: 0x78889F)
    static let tabInactiveDark = Color(hex: 0xA2AEC0)

    static func tabInactive(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? tabInactiveLight : tabInactiveDark
    }

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

    // ReadingStatsView's contribution graph uses a 5-step intensity ramp
    // (0 = no activity that day) as increasing ink opacity
    // over `BookShelfPalette`'s light background, rather than a hue ramp —
    // reads as dots lighting up, not a GitHub-style color-coded heatmap.
    // The dark stats graph uses these opacity levels with appPrimaryText via
    // statsIntensity below.
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

/// Shared light palette for My Shelf and reader chrome shown over light
/// reading themes.
enum BookShelfPalette {
    static let background = Color.whitePaper
    static let primaryText = Color(hex: 0x171715)
    static let secondaryText = Color(hex: 0x686761)
}

/// Shared dark surface used by full-height presentation chrome. Settings,
/// Stats, and Voice Library share one white sidebar lighting/grain treatment.
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

            switch variant {
            case .sidebar:
                SidebarTextureLayer(textureColor: .white, coreColor: .black)

            case .neutral:

                RadialGradient(
                    colors: [Color.white.opacity(0.22), .clear],
                    center: UnitPoint(x: 0.08, y: 0.86),
                    startRadius: 0,
                    endRadius: 430)

                RadialGradient(
                    colors: [Color.white.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.92, y: 0.08),
                    startRadius: 0,
                    endRadius: 340)

                RadialGradient(
                    colors: [Color.black.opacity(0.78), .clear],
                    center: UnitPoint(x: 0.30, y: 0.48),
                    startRadius: 10,
                    endRadius: 310)

                StaticFilmGrain(
                    spacing: 2.25,
                    intensity: 1,
                    bottomBoost: 0)
                    .blendMode(.softLight)
                    .opacity(0.94)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

/// The Settings sidebar texture mirrored for light editorial surfaces. It uses
/// the same lighting shapes, grain coordinates, density, and bottom weighting;
/// only the paper/core and texture colors are inverted.
struct TexturedLightBackground: View {
    var body: some View {
        ZStack {
            BookShelfPalette.background

            LinearGradient(
                colors: [BookShelfPalette.background, Color(hex: 0xFAFAFA), .white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            SidebarTextureLayer(textureColor: .black, coreColor: .white)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Settings' texture layer. Reader sheets reuse this view and swap only its
/// foreground/core colors, so geometry and grain cannot diverge.
private struct SidebarTextureLayer: View {
    let textureColor: Color
    let coreColor: Color

    var body: some View {
        SidebarSurfaceLighting(edgeColor: textureColor, coreColor: coreColor)

        StaticFilmGrain(
            spacing: 2,
            intensity: 1.08,
            bottomBoost: 0.55,
            color: textureColor)
            .blendMode(.softLight)
    }
}

/// One lighting shape shared by Settings and both reader-sheet palettes.
/// Swapping its two colors mirrors the composition without changing geometry.
private struct SidebarSurfaceLighting: View {
    let edgeColor: Color
    let coreColor: Color

    var body: some View {
        RadialGradient(
            colors: [edgeColor.opacity(0.42), .clear],
            center: UnitPoint(x: 0.50, y: 0.97),
            startRadius: 0,
            endRadius: 470)

        RadialGradient(
            colors: [edgeColor.opacity(0.26), .clear],
            center: UnitPoint(x: 1.04, y: 0.60),
            startRadius: 0,
            endRadius: 360)

        RadialGradient(
            colors: [edgeColor.opacity(0.10), .clear],
            center: UnitPoint(x: 0.92, y: 0.08),
            startRadius: 0,
            endRadius: 340)

        EllipticalGradient(
            colors: [
                coreColor.opacity(0.88),
                coreColor.opacity(0.74),
                .clear,
            ],
            center: UnitPoint(x: 0.36, y: 0.44),
            startRadiusFraction: 0,
            endRadiusFraction: 0.66)
    }
}

private struct StaticFilmGrain: View {
    let spacing: CGFloat
    let intensity: Double
    let bottomBoost: Double
    var color: Color?

    init(
        spacing: CGFloat,
        intensity: Double,
        bottomBoost: Double,
        color: Color? = nil
    ) {
        self.spacing = spacing
        self.intensity = intensity
        self.bottomBoost = bottomBoost
        self.color = color
    }

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
                    let dotColor = color
                        ?? (value.isMultiple(of: 3) ? Color.white : Color.black)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor.opacity(opacity)))
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

/// The reader page keeps its full theme palette; sheets and playback chrome
/// intentionally collapse those themes into these two presentation modes.
enum ReaderChromeTheme: Equatable {
    case light
    case dark

    init(readerTheme: ReaderTheme) {
        self = readerTheme.colorScheme == .dark ? .dark : .light
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var background: Color {
        switch self {
        case .light: return BookShelfPalette.background
        case .dark: return .appBackground
        }
    }

    var primaryText: Color {
        switch self {
        case .light: return BookShelfPalette.primaryText
        case .dark: return .appPrimaryText
        }
    }

    var secondaryText: Color {
        switch self {
        case .light: return BookShelfPalette.secondaryText
        case .dark: return .appSecondaryText
        }
    }

    var controlBackground: Color {
        switch self {
        case .light: return BookShelfPalette.primaryText.opacity(0.08)
        case .dark: return .appSecondaryBackground.opacity(0.92)
        }
    }

    var accent: Color {
        switch self {
        case .light: return BookShelfPalette.primaryText
        case .dark: return .appPrimaryText
        }
    }

    var contrastingText: Color {
        switch self {
        case .light: return BookShelfPalette.background
        case .dark: return .appBackground
        }
    }

    var border: Color { primaryText.opacity(0.10) }
    var shadow: Color { .black.opacity(self == .light ? 0.18 : 0.30) }
}

/// Edge-to-edge textured background for reader sheets. The compact player
/// uses the same colors without this grain layer.
struct ReaderChromeSheetBackground: View {
    let theme: ReaderChromeTheme

    @ViewBuilder
    var body: some View {
        switch theme {
        case .light:
            lightSurface
        case .dark:
            TexturedDarkBackground(variant: .sidebar)
        }
    }

    private var lightSurface: some View {
        TexturedLightBackground()
    }
}

/// Persistable color themes for long-form reading content. Floating controls
/// and reader sheets derive their two-mode palette through `chromeTheme`.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case white
    case paper
    case graphite
    case black
    case softGray

    var id: String { rawValue }

    var chromeTheme: ReaderChromeTheme {
        ReaderChromeTheme(readerTheme: self)
    }

    var title: String {
        switch self {
        case .white: return "White"
        case .paper: return "Paper"
        case .graphite: return "Graphite"
        case .black: return "Black"
        case .softGray: return "Soft Gray"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .graphite, .black: return .dark
        case .white, .paper, .softGray: return .light
        }
    }

    var background: Color {
        switch self {
        case .white: return Color(hex: 0xFFFFFF)
        case .paper: return Color(hex: 0xF1E2C9)
        case .graphite: return Color(hex: 0x2C2C2E)
        case .black: return Color(hex: 0x000000)
        case .softGray: return Color(hex: 0xE1E0E0)
        }
    }

    var primaryText: Color {
        switch self {
        case .white: return Color(hex: 0x000000)
        case .paper: return Color(hex: 0x2C241F)
        case .graphite: return Color(hex: 0xE1E0E0)
        case .black: return Color(hex: 0xFFFFFF)
        case .softGray: return Color(hex: 0x242526)
        }
    }

    var secondaryText: Color {
        switch self {
        case .white: return Color(hex: 0x5F6368)
        case .paper: return Color(hex: 0x6E5E52)
        case .graphite: return Color(hex: 0xAAA8A8)
        case .black: return Color(hex: 0xB8B8B8)
        case .softGray: return Color(hex: 0x66686B)
        }
    }

    var controlBackground: Color {
        switch self {
        case .white: return Color(hex: 0xF2F2F2).opacity(0.94)
        case .paper: return Color(hex: 0xE3CFAD).opacity(0.94)
        case .graphite: return Color(hex: 0x3A3A3C).opacity(0.94)
        case .black: return Color(hex: 0x1C1C1E).opacity(0.94)
        case .softGray: return Color(hex: 0xD1D0D0).opacity(0.94)
        }
    }

    var controlAccent: Color {
        switch self {
        case .white: return Color(hex: 0x000000)
        case .paper: return Color(hex: 0x6B4934)
        case .graphite: return Color(hex: 0xE1E0E0)
        case .black: return Color(hex: 0xFFFFFF)
        case .softGray: return Color(hex: 0x242526)
        }
    }

    var optionsAccent: Color { controlAccent }

    var chunkHighlightBackground: Color {
        switch self {
        case .white: return Color(hex: 0xEEF1F4)
        case .paper: return Color(hex: 0xE4CEA9)
        case .graphite: return Color(hex: 0x3B444A)
        case .black: return Color(hex: 0x17212A)
        case .softGray: return Color(hex: 0xCDD6D1)
        }
    }

    var wordHighlightBackground: Color {
        switch self {
        case .white: return Color(hex: 0xF2C94C)
        case .paper: return Color(hex: 0xC8894B)
        case .graphite: return Color(hex: 0x8FB5C8)
        case .black: return Color(hex: 0xE0B95B)
        case .softGray: return Color(hex: 0x91B39F)
        }
    }

    var highlightedText: Color {
        switch self {
        case .white: return Color(hex: 0x000000)
        case .paper: return Color(hex: 0x211813)
        case .graphite: return Color(hex: 0x111315)
        case .black: return Color(hex: 0x000000)
        case .softGray: return Color(hex: 0x152019)
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
