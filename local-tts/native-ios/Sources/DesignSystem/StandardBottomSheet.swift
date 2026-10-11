import SwiftUI

/// The content column's own horizontal inset, shared by every
/// `StandardBottomSheet` regardless of its `Content` type. A plain
/// non-generic holder rather than a `static` on the generic struct itself —
/// a generic type's static member still needs a concrete type argument to
/// reach from outside (`StandardBottomSheet<SomeView>.foo`), which would make
/// a caller that only wants this one number spell out a `Content` it doesn't
/// have. Exists so a caller wanting one piece of `content()` to bleed to the
/// sheet's true edge (`DayDetailView`'s empty-state marquee, matching how
/// About bleeds the same component to its own screen edge) can cancel exactly
/// this much with
/// `.padding(.horizontal, -StandardBottomSheetMetrics.contentHorizontalPadding)`
/// rather than a duplicated literal that could drift from the real value.
enum StandardBottomSheetMetrics {
    static let contentHorizontalPadding: CGFloat = 24
}

/// Shared chrome for the app's plain bottom sheets — Storage, Daily Goal,
/// Tools' catalog explainer, and the reader's own Pages/Reader
/// Options/Playback Speed sheets. A flat, opaque fill and a centered
/// system-serif title, with **no persistent close button** — dismissal is
/// the native drag-down the sheet's own indicator affords, not an
/// imperative `onClose` callback.
///
/// `theme` is what lets one component serve both groups: the plain utility
/// sheets have no reader theme to respect, so `nil` (the default) keeps the
/// original fixed `appBackground`/dark-color-scheme chrome; the reader
/// sheets pass their own `ReaderChromeTheme`, which can be a *light* reading
/// theme — forcing those dark would mismatch the page open behind them.
///
/// `onBack`, when non-nil, adds a small leading chevron beside the title for
/// in-sheet navigation (`ChapterPlayerOptionsSheet`'s Controls/Font pages).
/// It's deliberately not paired with a persistent Close the way
/// `InteractiveGlassBottomSheet` pairs Back with a fixed Close — the system
/// drag-down already dismisses from any nested page, so a second explicit
/// close control would only duplicate it.
struct StandardBottomSheet<Content: View>: View {
    let title: String
    let detents: Set<PresentationDetent>
    var theme: ReaderChromeTheme?
    var showsDragIndicator = true
    var onBack: (() -> Void)?
    /// Opt-in subtle grain/lighting behind the flat fill — the same
    /// `TexturedDarkBackground()` (`.neutral` variant) `AddCatalogSheet`
    /// paints on its own bespoke chrome. Defaults to `false` so every
    /// existing caller (Storage, Daily Goal, the catalog explainer, the
    /// reader's three sheets) keeps its plain flat fill unchanged; only a
    /// caller that explicitly asks gets the texture. Only meaningful when
    /// `theme` is nil — the dark-only utility-sheet case this and
    /// `AddCatalogSheet` both are; a reader sheet's *light* theme has no
    /// textured equivalent to fall back to.
    var isTextured = false
    @ViewBuilder let content: () -> Content

    private var background: Color { theme?.background ?? .appBackground }
    private var primaryText: Color { theme?.primaryText ?? .appPrimaryText }
    private var colorScheme: ColorScheme { theme?.colorScheme ?? .dark }

    var body: some View {
        ZStack {
            if isTextured {
                TexturedDarkBackground()
                    .ignoresSafeArea()
            } else {
                background
                    .ignoresSafeArea()
            }

            ScrollView {
                VStack(spacing: 24) {
                    titleRow
                    content()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, StandardBottomSheetMetrics.contentHorizontalPadding)
                .padding(.top, 32)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationBackground(.clear)
        .presentationDetents(detents)
        .presentationDragIndicator(showsDragIndicator ? .visible : .hidden)
        .preferredColorScheme(colorScheme)
    }

    @ViewBuilder
    private var titleRow: some View {
        // A literal 24pt rather than 34 + `.minimumScaleFactor`: only a long
        // title ever triggers that shrink, so short ones rendered at the full
        // 34 and looked bigger than the catalog explainer's despite sharing
        // this code. A fixed size is what actually makes them match.
        let titleText = Text(title)
            .font(.system(size: 24, weight: .regular, design: .serif))
            .foregroundStyle(primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .accessibilityAddTraits(.isHeader)

        if let onBack {
            ZStack {
                titleText
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(primaryText)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressOpacity)
                    .accessibilityLabel("Back")

                    Spacer(minLength: 0)
                }
            }
        } else {
            titleText
        }
    }
}
