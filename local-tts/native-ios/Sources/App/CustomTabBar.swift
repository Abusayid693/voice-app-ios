import Hugeicons
import LucideSwift
import SwiftUI

/// The floating Explore/Add Books bar. Explore expands *upwards* into a
/// vertical menu of Home's Explore destinations; Add Books stays put beside
/// it rather than sliding away, since the menu no longer needs its room.
struct CustomTabBar: View {
    @Binding var isExploreExpanded: Bool
    let safeAreaBottom: CGFloat
    let onSelect: (ExploreDestination) -> Void
    let onAddBooks: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let exploreSize: CGFloat = 60
    /// Gap between the bar and the menu that floats above it.
    private let menuGap: CGFloat = 10

    private var movementAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    // Every Explore destination is now pushed onto Home's own stack, which
    // hides this bar — so the bar only ever floats over the Book Shelf, and
    // its foreground is simply that screen's light palette. No per-tab
    // branching left to keep in sync.
    private let barForeground = BookShelfPalette.primaryText

    var body: some View {
        HStack(spacing: 12) {
            exploreButton
            addBooksButton
        }
        .padding(.horizontal, 19)
        .padding(.top, 9)
        .padding(.bottom, max(safeAreaBottom - 31, 8))
        .offset(y: 25)
    }

    private var exploreButton: some View {
        Button {
            withAnimation(movementAnimation) {
                isExploreExpanded.toggle()
            }
        } label: {
            ZStack {
                LucideIcon(.compass, size: 25, color: barForeground)
                    .rotationEffect(.degrees(isExploreExpanded ? -45 : 0))
                    .scaleEffect(isExploreExpanded ? 0.55 : 1)
                    .opacity(isExploreExpanded ? 0 : 1)

                LucideIcon(.x, size: 25, color: barForeground)
                    .rotationEffect(.degrees(isExploreExpanded ? 0 : 45))
                    .scaleEffect(isExploreExpanded ? 1 : 0.55)
                    .opacity(isExploreExpanded ? 1 : 0)
            }
            .frame(width: exploreSize, height: exploreSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(exploreBackground)
        // Clip to the exact circle before shadowing it — otherwise the
        // material background's shadow traces its full rectangular frame,
        // not the rounded silhouette, and shows as a boxy halo/bg color.
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        // An overlay, not a sibling in the bar's layout — the menu has to
        // grow upward over the page without changing the bar's own height
        // (which `.safeAreaInset` would otherwise turn into page inset).
        .overlay(alignment: .bottomLeading) {
            exploreMenu.offset(y: -(exploreSize + menuGap))
        }
        .accessibilityLabel(isExploreExpanded ? "Close navigation" : "Explore")
        .accessibilityHint(isExploreExpanded ? "Hides app sections" : "Shows app sections")
    }

    private var exploreMenu: some View {
        VStack(spacing: 2) {
            ForEach(Array(ExploreDestination.allCases.enumerated()), id: \.element) { index, destination in
                menuRow(destination, index: index)
            }
        }
        .padding(6)
        .frame(width: 196)
        .background(menuBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .scaleEffect(isExploreExpanded ? 1 : 0.72, anchor: .bottomLeading)
        .opacity(isExploreExpanded ? 1 : 0)
        .animation(movementAnimation, value: isExploreExpanded)
        .allowsHitTesting(isExploreExpanded)
        .accessibilityHidden(!isExploreExpanded)
    }

    private func menuRow(_ destination: ExploreDestination, index: Int) -> some View {
        // Rows settle bottom-up, so the motion reads as growing out of the
        // Explore button rather than dropping in from above.
        let delay = reduceMotion
            ? 0
            : Double(ExploreDestination.allCases.count - 1 - index) * 0.035

        return Button {
            onSelect(destination)
        } label: {
            HStack(spacing: 12) {
                destination.icon.image()
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(barForeground)
                    .frame(width: 21, height: 21)
                Text(destination.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(barForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isExploreExpanded ? 1 : 0)
        .offset(y: isExploreExpanded ? 0 : 10)
        .animation(movementAnimation.delay(delay), value: isExploreExpanded)
        .accessibilityLabel(destination.title)
    }

    private var addBooksButton: some View {
        Button(action: onAddBooks) {
            HStack(spacing: 8) {
                LucideIcon(.plus, size: 20, color: barForeground)
                Text("Add Books")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(barForeground)
            }
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

    // Genuine glass, not a tinted flat pill — no opaque color layered on
    // top of/under the glass effect, so it actually reads as translucent
    // Liquid Glass rather than a dark capsule that merely sits near glass.
    @ViewBuilder
    private var addBooksBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var exploreBackground: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular.interactive(), in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var menuBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular.interactive(), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
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
