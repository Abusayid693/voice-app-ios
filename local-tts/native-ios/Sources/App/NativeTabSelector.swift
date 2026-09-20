import LucideSwift
import SwiftUI
import UIKit

/// Hosts a real `UISegmentedControl` for the 4-tab selector so it renders
/// genuine OS chrome (Liquid Glass on iOS 26, classic segmented below it)
/// with no `#available` branching needed for the look itself.
///
/// Each segment's icon+label is rasterized once via `ImageRenderer` since
/// `UISegmentedControl` only takes an image per segment, not a live view.
/// Default per-segment background image views are hidden (alpha 0) so only
/// the rendered artwork and the sliding tint capsule show — walks internal,
/// undocumented view hierarchy, so it could break in a future OS release.
struct NativeTabSelector: UIViewRepresentable {
    @Binding var selectedTab: RootTab

    private let tabs = RootTab.allCases

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        for (index, tab) in tabs.enumerated() {
            let renderer = ImageRenderer(content: tabItemView(tab))
            renderer.scale = UIScreen.main.scale
            control.insertSegment(with: renderer.uiImage, at: index, animated: false)
        }
        control.selectedSegmentIndex = tabs.firstIndex(of: selectedTab) ?? 0
        control.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.22)
        // Opaque here would paint over the system's own glass rendering.
        control.backgroundColor = .clear

        DispatchQueue.main.async {
            for subview in control.subviews {
                if subview is UIImageView && subview != control.subviews.last {
                    subview.alpha = 0
                }
            }
        }

        control.addTarget(
            context.coordinator, action: #selector(Coordinator.tabSelected(_:)), for: .valueChanged)
        return control
    }

    // Pins the height explicitly so it stays in sync with CustomTabBar's layout.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 54)
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        // Syncs selection when selectedTab changes programmatically (not from a tap).
        let index = tabs.firstIndex(of: selectedTab) ?? 0
        if uiView.selectedSegmentIndex != index {
            uiView.selectedSegmentIndex = index
        }
    }

    private func tabItemView(_ tab: RootTab) -> some View {
        VStack(spacing: 2) {
            LucideIcon(tab.icon, size: 22, color: Color.appPrimaryText)
            Text(tab.title)
                .font(.system(size: 9))
                .foregroundStyle(Color.appPrimaryText)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    final class Coordinator: NSObject {
        private let parent: NativeTabSelector

        init(_ parent: NativeTabSelector) {
            self.parent = parent
        }

        @objc func tabSelected(_ sender: UISegmentedControl) {
            parent.selectedTab = parent.tabs[sender.selectedSegmentIndex]
        }
    }
}
