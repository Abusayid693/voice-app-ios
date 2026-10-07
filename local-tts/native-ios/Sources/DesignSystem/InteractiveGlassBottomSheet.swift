import SwiftUI

/// Edge-to-edge reader sheet chrome shared by Reader Options, Pages, and
/// Playback Speed. Callers own only their body content; this view owns the
/// interactive surface, presentation behavior, and floating blurred header.
struct InteractiveGlassBottomSheet<Content: View>: View {
    let theme: ReaderChromeTheme
    let detents: Set<PresentationDetent>
    let showsDragIndicator: Bool
    let closeAccessibilityLabel: String
    let contentTopInset: CGFloat
    let onClose: () -> Void
    let onBack: (() -> Void)?
    let content: (CGFloat) -> Content

    // headerButton is a fixed 44×44 — headerHeight must stay at or above
    // that, and blurHeight at or above headerHeight, or the Back/Close
    // buttons overflow past the blurred band onto the content below it.
    private let headerHeight: CGFloat = 44
    private let blurHeight: CGFloat = 60

    init(
        theme: ReaderChromeTheme,
        detents: Set<PresentationDetent>,
        showsDragIndicator: Bool = true,
        closeAccessibilityLabel: String = "Close",
        contentTopInset: CGFloat = 60,
        onClose: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.theme = theme
        self.detents = detents
        self.showsDragIndicator = showsDragIndicator
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.contentTopInset = contentTopInset
        self.onClose = onClose
        self.onBack = onBack
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .top) {
            content(contentTopInset)
            header
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(InteractiveGlassSheetSurface(theme: theme))
        .presentationDetents(detents)
        .presentationDragIndicator(showsDragIndicator ? .visible : .hidden)
        .presentationContentInteraction(.scrolls)
        .preferredColorScheme(theme.colorScheme)
    }

    private var header: some View {
        // Centered, not top-aligned: the button row is shorter than the
        // blurred band so it sits with even space above and below, rather
        // than flush against the top edge with the slack landing below it.
        ZStack {
            progressiveBlur

            HStack(spacing: 8) {
                if let onBack {
                    headerButton(
                        systemName: "chevron.left",
                        accessibilityLabel: "Back",
                        action: onBack)
                }

                Spacer(minLength: 8)

                headerButton(
                    systemName: "xmark",
                    accessibilityLabel: closeAccessibilityLabel,
                    action: onClose)
            }
            .frame(height: headerHeight)
            .padding(.horizontal, 10)
        }
        .frame(height: blurHeight, alignment: .top)
    }

    /// True variable-radius blur — strength follows a gradient, not a single
    /// fixed-radius `.ultraThinMaterial` faded by *opacity* (what was here
    /// before: full-strength blur for the band's own top 56%, then a quick
    /// alpha fade — a flat plateau, not a gradient). SwiftUI/UIKit have no
    /// public API for a true radius gradient; `VariableBlurView` is vendored
    /// rather than hand-rolled for the reason its own README gives. Composited
    /// directly over `content` with nothing opaque behind it in this band —
    /// see `InteractiveGlassSheetSurface` — so it reads as glass over
    /// whatever scrolled beneath, not a tinted color block.
    private var progressiveBlur: some View {
        ProgressiveHeaderBlur()
    }

    private func headerButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(InteractiveGlassHeaderButton())
        .frame(width: 44, height: 44)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// True top-to-bottom variable blur shared by sheet and reader headers.
struct ProgressiveHeaderBlur: View {
    var body: some View {
        VariableBlurView(maxBlurRadius: 12, direction: .blurredTopClearBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A clear glass circle on iOS 26; a material circle with normal SwiftUI
/// button feedback on earlier systems.
private struct InteractiveGlassHeaderButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Full-sheet static glass on iOS 26 and an opaque fallback below it. Both
/// paths keep the two-mode texture edge-to-edge behind scrolling content.
private struct InteractiveGlassSheetSurface: ViewModifier {
    let theme: ReaderChromeTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background {
                    ReaderChromeSheetBackground(theme: theme)
                        .ignoresSafeArea()
                }
                .glassEffect(
                    .regular.tint(theme.background),
                    in: Rectangle())
                .presentationBackground(.clear)
        } else {
            content
                .background {
                    ReaderChromeSheetBackground(theme: theme)
                        .ignoresSafeArea()
                }
                .presentationBackground(theme.background)
        }
    }
}
