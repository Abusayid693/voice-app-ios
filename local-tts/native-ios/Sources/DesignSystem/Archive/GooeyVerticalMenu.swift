import SwiftUI

// Archived for possible reuse; not part of the current app navigation.

struct GooeyVerticalMenuConfiguration {
    var buttonSize: CGFloat = 60
    var actionButtonSize: CGFloat = 40
    var spacing: CGFloat = 20
    var attachmentSpacing: CGFloat = 6
    var springResponse: Double = 0.42
    var springDamping: Double = 0.86
    var blurRadius: CGFloat = 10
    var alphaThreshold: Double = 0.5
    var stagger: CGFloat = 0.07
    var backgroundColor: Color = .accentColor
    var foregroundColor: Color = .white
    var shadowColor: Color = .black.opacity(0.22)
    var shadowRadius: CGFloat = 9
    var shadowYOffset: CGFloat = 4
}

/// Items run nearest-to-farthest. The overlay reserves only the main button's size.
struct GooeyVerticalMenu<Item: Identifiable, MainIcon: View, ItemIcon: View>: View {
    @Binding private var isExpanded: Bool
    private let items: [Item]
    private let configuration: GooeyVerticalMenuConfiguration
    private let mainAccessibilityLabel: (Bool) -> String
    private let itemAccessibilityLabel: (Item) -> String
    private let onSelect: (Item) -> Void
    private let mainIcon: (CGFloat) -> MainIcon
    private let itemIcon: (Item) -> ItemIcon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var animationID = UUID()
    @State private var pendingSelection: Item?
    @State private var acceptsSelection = false

    init(
        isExpanded: Binding<Bool>,
        items: [Item],
        configuration: GooeyVerticalMenuConfiguration = .init(),
        mainAccessibilityLabel: @escaping (Bool) -> String,
        itemAccessibilityLabel: @escaping (Item) -> String,
        onSelect: @escaping (Item) -> Void,
        @ViewBuilder mainIcon: @escaping (CGFloat) -> MainIcon,
        @ViewBuilder itemIcon: @escaping (Item) -> ItemIcon
    ) {
        _isExpanded = isExpanded
        self.items = items
        self.configuration = configuration
        self.mainAccessibilityLabel = mainAccessibilityLabel
        self.itemAccessibilityLabel = itemAccessibilityLabel
        self.onSelect = onSelect
        self.mainIcon = mainIcon
        self.itemIcon = itemIcon
    }

    var body: some View {
        Color.clear
            .frame(width: configuration.buttonSize, height: configuration.buttonSize)
            .overlay(alignment: .bottom) {
                GooeyMenuSurface(
                    progress: progress,
                    items: items,
                    configuration: configuration,
                    reduceMotion: reduceMotion,
                    isExpanded: isExpanded,
                    acceptsSelection: acceptsSelection && isExpanded,
                    mainAccessibilityLabel: mainAccessibilityLabel,
                    itemAccessibilityLabel: itemAccessibilityLabel,
                    toggle: {
                        pendingSelection = nil
                        isExpanded.toggle()
                    },
                    select: { item in
                        guard acceptsSelection, isExpanded, pendingSelection == nil else { return }
                        pendingSelection = item
                        acceptsSelection = false
                        isExpanded = false
                    },
                    mainIcon: mainIcon,
                    itemIcon: itemIcon)
            }
            .onChange(of: isExpanded, initial: true) { _, expanded in
                animate(to: expanded)
            }
            .onChange(of: reduceMotion) { _, _ in
                animate(to: isExpanded)
            }
            .onDisappear {
                animationID = UUID()
                pendingSelection = nil
                acceptsSelection = false
            }
    }

    private func animate(to expanded: Bool) {
        let id = UUID()
        animationID = id
        acceptsSelection = false
        if expanded { pendingSelection = nil }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(
                response: max(configuration.springResponse, 0.1),
                dampingFraction: max(configuration.springDamping, 0.5))

        withAnimation(animation, completionCriteria: .removed) {
            progress = expanded ? 1 : 0
        } completion: {
            guard animationID == id, isExpanded == expanded else { return }
            acceptsSelection = expanded
            if !expanded, let selected = pendingSelection {
                pendingSelection = nil
                onSelect(selected)
            }
        }
    }
}

/// Interpolating here makes Canvas and glyphs consume the same presentation value.
private struct GooeyMenuSurface<Item: Identifiable, MainIcon: View, ItemIcon: View>: View, Animatable {
    var progress: CGFloat
    let items: [Item]
    let configuration: GooeyVerticalMenuConfiguration
    let reduceMotion: Bool
    let isExpanded: Bool
    let acceptsSelection: Bool
    let mainAccessibilityLabel: (Bool) -> String
    let itemAccessibilityLabel: (Item) -> String
    let toggle: () -> Void
    let select: (Item) -> Void
    let mainIcon: (CGFloat) -> MainIcon
    let itemIcon: (Item) -> ItemIcon

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var geometry: GooeyMenuGeometry {
        GooeyMenuGeometry(configuration: configuration, itemCount: items.count)
    }

    var body: some View {
        let geometry = geometry
        ZStack(alignment: .bottom) {
            backgrounds(geometry)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let fraction = geometry.fraction(progress: progress, index: index)
                let distance = geometry.distance(index: index)
                let offset = reduceMotion ? distance : distance * fraction
                // Reveal an icon as its circle clears the main button.
                let visibility = reduceMotion
                    ? geometry.clamp(progress)
                    : geometry.smoothstep((offset - configuration.buttonSize * 0.3) / 24)

                Button { select(item) } label: {
                    itemIcon(item)
                        .foregroundStyle(configuration.foregroundColor)
                        .frame(width: geometry.hitSize, height: geometry.hitSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(y: (geometry.hitSize - configuration.buttonSize) / 2 - offset)
                .opacity(visibility)
                .allowsHitTesting(acceptsSelection)
                .accessibilityHidden(!acceptsSelection)
                .accessibilityLabel(itemAccessibilityLabel(item))
            }

            Button(action: toggle) {
                mainIcon(geometry.clamp(progress))
                    .foregroundStyle(configuration.foregroundColor)
                    .frame(width: configuration.buttonSize, height: configuration.buttonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mainAccessibilityLabel(isExpanded))
            .accessibilityHint(isExpanded ? "Hides app sections" : "Shows app sections")
        }
        .frame(width: configuration.buttonSize, height: geometry.height, alignment: .bottom)
        // All presentation interpolation belongs to this surface, not its descendants.
        .transaction { $0.animation = nil }
    }

    private func backgrounds(_ geometry: GooeyMenuGeometry) -> some View {
        Canvas { context, _ in
            let origin = CGPoint(
                x: configuration.buttonSize / 2 + geometry.padding,
                y: geometry.height - configuration.buttonSize / 2 + geometry.padding)
            if !reduceMotion {
                context.addFilter(.alphaThreshold(
                    min: min(max(configuration.alphaThreshold, 0.05), 0.95),
                    color: configuration.backgroundColor))
                context.addFilter(.blur(radius: max(configuration.blurRadius, 0)))
            }
            context.drawLayer { layer in
                let ink: Color = reduceMotion ? configuration.backgroundColor : .white
                let mainRect = CGRect(
                    x: origin.x - configuration.buttonSize / 2,
                    y: origin.y - configuration.buttonSize / 2,
                    width: configuration.buttonSize,
                    height: configuration.buttonSize)
                layer.fill(Path(ellipseIn: mainRect), with: .color(ink))
                for index in items.indices {
                    let fraction = geometry.fraction(progress: progress, index: index)
                    let distance = geometry.distance(index: index)
                    let offset = reduceMotion ? distance : distance * fraction
                    let radius = configuration.actionButtonSize / 2
                    let rect = CGRect(
                        x: origin.x - radius,
                        y: origin.y - offset - radius,
                        width: radius * 2,
                        height: radius * 2)
                    layer.opacity = reduceMotion ? Double(geometry.clamp(progress)) : 1
                    layer.fill(Path(ellipseIn: rect), with: .color(ink))
                }
            }
        }
        // Padding gives the Gaussian kernel room on every edge, including below the FAB.
        .frame(
            width: configuration.buttonSize + 2 * geometry.padding,
            height: geometry.height + 2 * geometry.padding)
        .shadow(
            color: configuration.shadowColor,
            radius: configuration.shadowRadius,
            y: configuration.shadowYOffset)
        .frame(width: configuration.buttonSize, height: geometry.height)
    }
}

private struct GooeyMenuGeometry {
    let configuration: GooeyVerticalMenuConfiguration
    let itemCount: Int

    var hitSize: CGFloat { max(44, configuration.actionButtonSize) }
    var padding: CGFloat { max(16, configuration.blurRadius * 3) }
    var height: CGFloat {
        guard itemCount > 0 else { return configuration.buttonSize }
        return configuration.buttonSize / 2 + distance(index: itemCount - 1) + hitSize / 2
    }

    func distance(index: Int) -> CGFloat {
        (configuration.buttonSize + configuration.actionButtonSize) / 2
            + configuration.attachmentSpacing
            + CGFloat(index) * (configuration.actionButtonSize + configuration.spacing)
    }

    func fraction(progress: CGFloat, index: Int) -> CGFloat {
        // Bound the total stagger so any configured item count can reach its destination.
        let lag = min(max(configuration.stagger, 0), 0.3 / CGFloat(max(itemCount - 1, 1)))
        let start = CGFloat(index) * lag
        return smoothstep((progress - start) / (1 - start))
    }

    func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
}

private struct GooeyMenuPreviewItem: Identifiable {
    let id: String
    let symbol: String
}

private struct GooeyVerticalMenuPreview: View {
    @State private var isExpanded = false

    private let items = [
        GooeyMenuPreviewItem(id: "search", symbol: "magnifyingglass"),
        GooeyMenuPreviewItem(id: "bell", symbol: "bell"),
        GooeyMenuPreviewItem(id: "message", symbol: "message"),
        GooeyMenuPreviewItem(id: "person", symbol: "person")
    ]

    var body: some View {
        GooeyVerticalMenu(
            isExpanded: $isExpanded,
            items: items,
            configuration: .init(backgroundColor: .black),
            mainAccessibilityLabel: { $0 ? "Close actions" : "Open actions" },
            itemAccessibilityLabel: { $0.id.capitalized },
            onSelect: { _ in }
        ) { progress in
            Image(systemName: "plus")
                .font(.system(size: 23, weight: .regular))
                .rotationEffect(.degrees(45 * Double(progress)))
        } itemIcon: { item in
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .regular))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 40)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

#Preview("Gooey vertical menu") {
    GooeyVerticalMenuPreview()
}
