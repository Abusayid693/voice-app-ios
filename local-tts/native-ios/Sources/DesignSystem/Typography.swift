import SwiftUI

/// The app's font scale — every `.font(...)` call site should read from
/// here rather than a literal system style, so changing a tier (e.g.
/// making card titles bigger) moves every consumer of that tier at once
/// instead of requiring a sweep across files. Mirrors `Colors.swift`'s
/// shape: a flat `extension Font` of `static let` tokens, orthogonal to
/// color — callers still chain their own `.foregroundStyle(...)`.
///
/// Each token is an explicit size/weight (`Font.system(size:weight:)`)
/// rather than a named system style, by request — still scales with
/// Dynamic Type the same way a semantic style does, it just doesn't track
/// one. Several screens use fixed-point frames (e.g. Import's 327-wide
/// promo card, its 268x84 voice tile) that can clip before text this size
/// reflows — a pre-existing hazard, not introduced here, and not
/// addressed by this file.
extension Font {
    /// In-content hero/sheet heading, e.g. a recording timer readout.
    static let appTitle = Font.system(size: 32, weight: .medium)
    /// Long-form reading/editing text — read-along chunks, the write/edit
    /// text areas, a saved generation's original text.
    static let appReading = Font.system(size: 17, weight: .regular)
    /// A section header sitting above a horizontally scrolling row.
    static let appSectionTitle = Font.system(size: 18, weight: .medium)
    /// A card's own title (voice tile, book cover, hero card).
    static let appCardTitle = Font.system(size: 16, weight: .medium)
    /// A primary CTA's label.
    static let appButtonLabel = Font.system(size: 16, weight: .medium)
    /// A list/row title — settings rows, project rows, action tiles.
    static let appRowTitle = Font.system(size: 16, weight: .medium)
    /// Secondary prose: a row's subtitle, a settings value, an error
    /// message, body copy under a heading.
    static let appBody = Font.system(size: 16, weight: .medium)
    /// A compact card's title, or a pill/badge label.
    static let appLabelStrong = Font.system(size: 14, weight: .medium)
    /// A card's description/subtitle, a byline, a small text button.
    static let appLabel = Font.system(size: 14, weight: .regular)
    /// The finest tier: timestamps, file sizes, progress percentages.
    static let appMeta = Font.system(size: 12, weight: .medium)
}
