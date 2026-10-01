import SwiftUI

/// Edge-to-edge reader sheet chrome shared by Reader Options, Pages, and
/// Playback Speed. Callers own only their body content; this view owns the
/// interactive surface, presentation behavior, and floating blurred header.
struct InteractiveGlassBottomSheet<Content: View>: View {
    let theme: ReaderTheme
    let detents: Set<PresentationDetent>
    let showsDragIndicator: Bool
    let closeAccessibilityLabel: String
    let contentTopInset: CGFloat
    let onClose: () -> Void
    let onBack: (() -> Void)?
    let content: (CGFloat) -> Content

    private let headerHeight: CGFloat = 54
    private let blurHeight: CGFloat = 78

    init(
        theme: ReaderTheme,
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
        ZStack(alignment: .top) {
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

    private var progressiveBlur: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.56),
                        .init(color: .black.opacity(0.32), location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func headerButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.optionsAccent)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(InteractiveGlassHeaderButton())
        .frame(width: 44, height: 44)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The native local highlight and compression response on iOS 26; a material
/// circle with normal SwiftUI button feedback on earlier systems.
private struct InteractiveGlassHeaderButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Full-sheet interactive glass on iOS 26. The surface remains rectangular
/// and edge-to-edge; older systems use an opaque reader-theme background.
private struct InteractiveGlassSheetSurface: ViewModifier {
    let theme: ReaderTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(theme.background.opacity(0.82).ignoresSafeArea())
                .glassEffect(
                    .regular.tint(theme.background).interactive(),
                    in: Rectangle())
                .presentationBackground(.clear)
        } else {
            content
                .background(theme.background.ignoresSafeArea())
                .presentationBackground(theme.background)
        }
    }
}
