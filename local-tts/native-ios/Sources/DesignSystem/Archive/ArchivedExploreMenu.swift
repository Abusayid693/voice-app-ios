import Hugeicons
import LucideSwift
import SwiftUI

/// Archived presentation wrapper for the former Explore navigation control.
/// Items are supplied nearest-to-farthest from the main button. Selection is
/// delivered only after the liquid menu has completed its reverse collapse.
struct ArchivedExploreMenu<Item: Identifiable, ItemIcon: View>: View {
    @Binding private var isExpanded: Bool
    private let items: [Item]
    private let itemAccessibilityLabel: (Item) -> String
    private let onSelect: (Item) -> Void
    private let itemIcon: (Item) -> ItemIcon

    private let size: CGFloat = 60
    private let foreground = Color.appPrimaryText

    init(
        isExpanded: Binding<Bool>,
        items: [Item],
        itemAccessibilityLabel: @escaping (Item) -> String,
        onSelect: @escaping (Item) -> Void,
        @ViewBuilder itemIcon: @escaping (Item) -> ItemIcon
    ) {
        _isExpanded = isExpanded
        self.items = items
        self.itemAccessibilityLabel = itemAccessibilityLabel
        self.onSelect = onSelect
        self.itemIcon = itemIcon
    }

    var body: some View {
        GooeyVerticalMenu(
            isExpanded: $isExpanded,
            items: items,
            configuration: configuration,
            mainAccessibilityLabel: { $0 ? "Close navigation" : "Explore" },
            itemAccessibilityLabel: itemAccessibilityLabel,
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

                LucideIcon(.x, size: 25, color: foreground)
                    .rotationEffect(.degrees(45 * Double(1 - progress)))
                    .scaleEffect(0.6 + (0.4 * progress))
                    .opacity(progress)
            }
        } itemIcon: { item in
            itemIcon(item)
        }
    }

    private var configuration: GooeyVerticalMenuConfiguration {
        GooeyVerticalMenuConfiguration(
            buttonSize: size,
            actionButtonSize: size,
            spacing: 15,
            attachmentSpacing: 6,
            springResponse: 0.42,
            springDamping: 0.86,
            blurRadius: 10,
            alphaThreshold: 0.5,
            stagger: 0.07,
            backgroundColor: .appBackground,
            foregroundColor: foreground,
            shadowColor: .black.opacity(0.22),
            shadowRadius: 9,
            shadowYOffset: 4)
    }
}

private struct ArchivedExplorePreviewItem: Identifiable {
    let id: String
    let icon: String
}

private struct ArchivedExploreMenuPreview: View {
    @State private var isExpanded = true

    private let items = [
        ArchivedExplorePreviewItem(id: "library", icon: "rectangle.stack"),
        ArchivedExplorePreviewItem(id: "tools", icon: "wrench.and.screwdriver"),
        ArchivedExplorePreviewItem(id: "stats", icon: "chart.bar.xaxis"),
    ]

    var body: some View {
        ArchivedExploreMenu(
            isExpanded: $isExpanded,
            items: items,
            itemAccessibilityLabel: { $0.id.capitalized },
            onSelect: { _ in }
        ) { item in
            Image(systemName: item.icon)
                .font(.system(size: 20, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(24)
        .background(Color.whitePaper)
    }
}

#Preview {
    ArchivedExploreMenuPreview()
}
