import SwiftUI

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
    @ViewBuilder let content: () -> Content

    private var background: Color { theme?.background ?? .appBackground }
    private var primaryText: Color { theme?.primaryText ?? .appPrimaryText }
    private var colorScheme: ColorScheme { theme?.colorScheme ?? .dark }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    titleRow
                    content()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
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
