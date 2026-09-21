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
        HStack(spacing: 14) {
            tabSelector
            plusButton
        }
        .padding(.horizontal, 19)
        .padding(.top, 9)
        .padding(.bottom, max(safeAreaBottom - 31, 8))
        .offset(y: 25)
    }

    // .glassEffect() is iOS 26+ only; falls back to the app's usual
    // .ultraThinMaterial capsule treatment below that.
    @ViewBuilder
    private var tabSelector: some View {
        if #available(iOS 26.0, *) {
            NativeTabSelector(selectedTab: $selectedTab)
                .padding(2.5)
                .glassEffect(.regular, in: Capsule())
        } else {
            NativeTabSelector(selectedTab: $selectedTab)
                .padding(2.5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var plusButton: some View {
        Button(action: onPlusTapped) {
            LucideIcon(.plus, size: 27, color: Color.primaryButtonText)
                .frame(width: 60, height: 60)
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
