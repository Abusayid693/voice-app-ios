import Hugeicons
import LucideSwift
import SwiftUI

/// The floating Explore/Add Books bar. Explore expands *upwards* into a
/// vertical icon menu of Home's destinations; Add Books remains independent.
struct CustomTabBar: View {
    @Binding var isExploreExpanded: Bool
    let safeAreaBottom: CGFloat
    let onSelect: (ExploreDestination) -> Void
    let onAddBooks: () -> Void

    private let exploreSize: CGFloat = 60
    private let exploreForeground = Color.appPrimaryText

    private var exploreItems: [ExploreDestination] {
        // GooeyVerticalMenu expects nearest-to-farthest. Reversing preserves
        // the existing visible top-to-bottom order: Library, Voices, Tools.
        Array(ExploreDestination.allCases.reversed())
    }

    private var exploreConfiguration: GooeyVerticalMenuConfiguration {
        GooeyVerticalMenuConfiguration(
            buttonSize: exploreSize,
            actionButtonSize: exploreSize,
            spacing: 15,
            attachmentSpacing: 6,
            springResponse: 0.42,
            springDamping: 0.86,
            blurRadius: 10,
            alphaThreshold: 0.5,
            stagger: 0.07,
            backgroundColor: .appBackground,
            foregroundColor: exploreForeground,
            shadowColor: .black.opacity(0.22),
            shadowRadius: 9,
            shadowYOffset: 4)
    }

    var body: some View {
        // Add Books centers on the bar's own full width, not on the space
        // left over after Explore — a plain HStack with a Spacer either side
        // centers within the *remaining* space, which Explore's own width
        // skews off the bar's true midpoint. Overlaying Explore instead
        // (pinned leading) leaves this frame's own centering unaffected by it.
        ZStack {
            addBooksButton
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { exploreMenu }
        .padding(.horizontal, 19)
        .padding(.top, 9)
        .padding(.bottom, max(safeAreaBottom - 31, 8))
        .offset(y: 25)
    }

    private var exploreMenu: some View {
        GooeyVerticalMenu(
            isExpanded: $isExploreExpanded,
            items: exploreItems,
            configuration: exploreConfiguration,
            mainAccessibilityLabel: { $0 ? "Close navigation" : "Explore" },
            itemAccessibilityLabel: { $0.title },
            onSelect: onSelect
        ) { progress in
            ZStack {
                Hugeicons.menuSquare.image()
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .rotationEffect(.degrees(-45 * Double(progress)))
                    .scaleEffect(1 - (0.4 * progress))
                    .opacity(1 - progress)

                LucideIcon(.x, size: 25, color: exploreForeground)
                    .rotationEffect(.degrees(45 * Double(1 - progress)))
                    .scaleEffect(0.6 + (0.4 * progress))
                    .opacity(progress)
            }
        } itemIcon: { destination in
            destination.icon.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        }
    }

    // Solid dark, the same `.appBackground`/`.appPrimaryText` pair the
    // Explore button uses, so the two read as one family rather than a dark
    // circle beside a glass pill. It is still not part of the Explore menu's
    // filtered Canvas/metaball animation.
    private var addBooksButton: some View {
        Button(action: onAddBooks) {
            Text("Add Books")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(exploreForeground)
                .padding(.horizontal, 32)
                .frame(height: exploreSize)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.appBackground))
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        .accessibilityLabel("Add Books")
        .accessibilityHint("Choose a PDF to add to your shelf")
    }
}

#Preview {
    CustomTabBar(
        isExploreExpanded: .constant(true),
        safeAreaBottom: 34,
        onSelect: { _ in },
        onAddBooks: {})
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color.whitePaper)
}
