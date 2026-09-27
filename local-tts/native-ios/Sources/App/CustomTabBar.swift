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
    private let barForeground = BookShelfPalette.primaryText
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
        HStack(spacing: 12) {
            exploreMenu
            addBooksButton
        }
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

    private var addBooksButton: some View {
        Button(action: onAddBooks) {
            Text("Add Books")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(barForeground)
            .frame(maxWidth: .infinity)
            .frame(height: exploreSize)
        }
        .buttonStyle(.plain)
        .background(addBooksBackground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .accessibilityLabel("Add Books")
        .accessibilityHint("Choose a PDF to add to your shelf")
    }

    // Add Books deliberately keeps its original glass implementation. It is
    // not part of the Explore menu's filtered Canvas/metaball animation.
    @ViewBuilder
    private var addBooksBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
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
