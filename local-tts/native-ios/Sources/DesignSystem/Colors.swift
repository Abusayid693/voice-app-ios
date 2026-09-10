import SwiftUI

/// Fixed dark palette for the Import screen and its sheets (matches the
/// supplied mockup) — not theme-adaptive, used deliberately regardless of
/// system light/dark mode.
extension Color {
    static let appBackground = Color(hex: 0x292929)
    static let appSecondaryBackground = Color(hex: 0x313131)
    static let appPrimaryText = Color(hex: 0xEEEEEE)
    static let appSecondaryText = Color(hex: 0xB3B3B3)
    static let appTertiaryText = Color(hex: 0x6E6E6E)

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
    /// (a voice code, a book id) — the same seed always yields the same
    /// colors, so a placeholder shown while real artwork loads (or because
    /// it never loads) doesn't flicker to a different color on every
    /// redraw.
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
