import LucideSwift
import SwiftUI

/// Replaces the native `TabView` tab bar entirely: `NativeTabSelector` (a
/// real hosted `UISegmentedControl`, see that file) holding the 4 tabs,
/// plus a separate white circular "+" button. Hiding/showing this whole bar
/// is one `.transition`/`.animation` in `RootTabView` — see
/// `NavigationChromeVisibility` for why that matters.
struct CustomTabBar: View {
    @Binding var selectedTab: RootTab
    let safeAreaBottom: CGFloat
    let onPlusTapped: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            tabSelector
            plusButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, max(safeAreaBottom - 31, 8))
    }

    // .glassEffect() is iOS 26+ only; falls back to the app's usual
    // .ultraThinMaterial capsule treatment below that.
    @ViewBuilder
    private var tabSelector: some View {
        if #available(iOS 26.0, *) {
            NativeTabSelector(selectedTab: $selectedTab)
                .padding(2)
                .glassEffect(.regular, in: Capsule())
        } else {
            NativeTabSelector(selectedTab: $selectedTab)
                .padding(2)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var plusButton: some View {
        Button(action: onPlusTapped) {
            LucideIcon(.plus, size: 24, color: Color.primaryButtonText)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick actions")
    }
}

#Preview {
    CustomTabBar(selectedTab: .constant(.home), safeAreaBottom: 34, onPlusTapped: {})
        .background(Color.appBackground)
}
