import SwiftUI

/// Persistable reading-size choices used by long-form reader surfaces.
/// Medium preserves the app's original 17-point reading size.
enum ReaderFontSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 17
        case .large: return 21
        }
    }

    func font(family: ReaderFontFamily) -> Font {
        family.font(size: pointSize)
    }

    /// A heading's font, scaled off whatever body size the reader is set to.
    ///
    /// `scale` and `bold` come from the source document — an imported PDF's own
    /// heading is measured against its own body text, so a title the author set
    /// at 1.8x stays 1.8x here. That keeps the document's hierarchy instead of
    /// imposing a fixed one, and it still tracks the reader's font preference
    /// because it multiplies `pointSize` rather than replacing it.
    func font(family: ReaderFontFamily, scale: Double, bold: Bool) -> Font {
        family.font(size: pointSize * CGFloat(scale), weight: bold ? .bold : .regular)
    }
}

/// Persistable typefaces used only by the chapter reader's long-form text.
/// App chrome and every other screen continue to use `AppTextStyle`.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case sfProText
    case newYork
    case georgia
    case timesNewRoman
    case avenirNext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfProText: return "SF Pro Text"
        case .newYork: return "New York"
        case .georgia: return "Georgia"
        case .timesNewRoman: return "Times New Roman"
        case .avenirNext: return "Avenir Next"
        }
    }

    func font(size: CGFloat) -> Font {
        font(size: size, weight: .regular)
    }

    /// The two `.custom` families need their bold face by name — `.bold()` on a
    /// custom font synthesises the weight rather than using the real one.
    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .sfProText:
            return .system(size: size, weight: weight, design: .default)
        case .newYork:
            // The system serif design resolves to Apple's New York family
            // and follows the platform's optical-size behavior.
            return .system(size: size, weight: weight, design: .serif)
        case .georgia:
            return .custom(weight == .regular ? "Georgia" : "Georgia-Bold", size: size)
        case .timesNewRoman:
            return .custom(
                weight == .regular ? "TimesNewRomanPSMT" : "TimesNewRomanPS-BoldMT", size: size)
        case .avenirNext:
            return .custom(
                weight == .regular ? "AvenirNext-Regular" : "AvenirNext-DemiBold", size: size)
        }
    }
}

/// The app's text-style scale — every piece of text reads from one of
/// these cases via `.appText(_:)` rather than composing `.font(...)` +
/// `.foregroundStyle(...)` by hand. Color lives in the style, not just
/// font: left as two separate calls at each site, the pairing drifted for
/// real — `appLabel`-equivalent text alone ended up with 5 different
/// colors across 24 call sites before this. A view never passes a color;
/// the style decides.
///
/// Each case is an explicit `Font.system(size:weight:)` rather than a
/// named system style — still scales with Dynamic Type the same way a
/// semantic style does, it just doesn't track one. Several screens use
/// fixed-point frames (e.g. Import's 327-wide promo card, its 268x84
/// voice tile) that can clip before text this size reflows — a
/// pre-existing hazard, not introduced here, and not addressed by this
/// file.
enum AppTextStyle {
    /// In-content hero/sheet heading.
    case title
    /// Same heading, over photographic imagery rather than appBackground.
    case titleOnImage
    /// A section header sitting above a horizontally scrolling row.
    case sectionTitle
    /// A card's own title (voice tile, book cover, hero card).
    case cardTitle
    /// A list/row title — settings rows, project rows, action tiles.
    case rowTitle
    /// Secondary prose: a row's subtitle, a settings value, body copy
    /// under a heading.
    case body
    /// The same tier, promoted to primary — a row's own title text when
    /// it's built via `LabeledContent`, a summary/total value.
    case bodyStrong
    /// A card's description/subtitle, a byline, a small text button.
    case label
    /// The same tier, dimmed further — a card's description when it
    /// should read as less prominent than a byline (see `label` vs.
    /// `labelDim`'s call sites for the distinction this preserves).
    case labelDim
    /// A compact card's own title, or a pill/badge label.
    case labelStrong
    /// The finest tier: timestamps, file sizes, progress percentages.
    case meta

    var font: Font {
        switch self {
        case .title:
            return .system(size: 32, weight: .medium)
        case .titleOnImage:
            return .system(size: 24, weight: .medium)
        case .sectionTitle:
            return .system(size: 18, weight: .medium)
        case .cardTitle, .rowTitle, .body, .bodyStrong:
            return .system(size: 16, weight: .medium)
        case .labelStrong:
            return .system(size: 14, weight: .medium)
        case .label, .labelDim:
            return .system(size: 14, weight: .regular)
        case .meta:
            return .system(size: 12, weight: .medium)
        }
    }

    fileprivate var color: Color {
        switch self {
        case .title, .sectionTitle, .cardTitle, .rowTitle, .bodyStrong, .labelStrong:
            return .appPrimaryText
        case .titleOnImage:
            return .white
        case .body, .label:
            return .appSecondaryText
        case .labelDim:
            return .appTertiaryText
        case .meta:
            return .appMetaText
        }
    }
}

extension View {
    /// Applies an `AppTextStyle`'s font and color together. Works on
    /// `Text`, `TextEditor`, `Label`, `LabeledContent`, and string-init
    /// `Button`s alike — anything that reads `.font`/`.foregroundStyle`
    /// from the environment.
    func appText(_ style: AppTextStyle) -> some View {
        font(style.font).foregroundStyle(style.color)
    }

    /// The "Free Demo"/"OPEN SOURCE" pill treatment — font, text color,
    /// capsule fill, and padding all live here so a highlight badge can't
    /// drift the way it had (3 near-identical pills, 3 different color
    /// pairs, before this).
    func appHighlightLabel() -> some View {
        font(AppTextStyle.labelStrong.font)
            .foregroundStyle(Color.highlightBadgeText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.highlightBadgeBackground))
    }
}
