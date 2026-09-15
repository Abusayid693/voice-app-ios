import SwiftUI

/// Fixed dark palette for the Import screen and its sheets (matches the
/// supplied mockup) — not theme-adaptive, used deliberately regardless of
/// system light/dark mode.
extension Color {
    static let appBackground = Color(hex: 0x1D1D1C)
    static let appSecondaryBackground = Color(hex: 0x242323)
    static let appPrimaryText = Color(hex: 0xEEEEEE)
    static let appSecondaryText = Color(hex: 0xB3B3B3)
    static let appTertiaryText = Color(hex: 0x6E6E6E)
    // Deliberately lighter/warmer than appTertiaryText — the finest
    // metadata tier (timestamps, file sizes) reads as its own color, not
    // just a dimmer tertiary.
    static let appMetaText = Color(hex: 0xAB9E9A)

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

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
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
