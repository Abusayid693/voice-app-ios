import SwiftUI

/// Whether `RootTabView`'s custom bottom bar (`CustomTabBar` — the 4 tabs
/// and the "+" button, all in one row) should be visible — true only while
/// every tab's own `NavigationStack` sits at its root screen (Home/Library/
/// Tools/Voices), false the moment anything is pushed within any of them.
///
/// There used to be two separate hiding mechanisms here: the real
/// `UITabBar` via `.toolbar(.hidden, for: .tabBar)` (UIKit-transition-
/// timed) and this object driving a separately-floating "+" button
/// (SwiftUI-`.animation`-timed). Those two clocks kept visibly desyncing —
/// the "+" button appearing before the real tab bar finished reappearing —
/// and no amount of re-tuning the animation duration fixed it, because
/// there were structurally two systems to keep in sync. Replacing the
/// native tab bar with `CustomTabBar` collapsed that back to one: this
/// object now drives the *entire* bar's visibility through one
/// `.transition`/`.animation` in `RootTabView`, so there's nothing left to
/// desync against.
///
/// Driven by each tab root's own push-triggering `@State` (`openProjectID`,
/// `voiceCloneRoute`, …) via `.onChange`, not by the pushed screens
/// themselves. Pushing a new screen in a `NavigationStack` also fires the
/// *previous* screen's `.onDisappear`, so two screens independently
/// toggling one shared flag on appear/disappear can race and land wrong
/// depending on ordering. A tab root's own state doesn't have that problem:
/// it's one value, changed in one place, and stays non-nil for as long as
/// anything is pushed under it however many levels deep — so reading it
/// straight from the presenter is both simpler and race-free.
@MainActor
final class NavigationChromeVisibility: ObservableObject {
    @Published var isAtTabRoot = true
}

extension View {
    /// Keeps `chrome.isAtTabRoot` in sync with whether this tab root
    /// currently has something pushed. `.onAppear` (not just `.onChange`)
    /// matters: without it, the flag is only ever written when `isPushed`
    /// itself changes, so if anything ever left it stale — a future
    /// programmatic tab switch, a deep link — there'd be no way back to a
    /// visible tab bar short of triggering another push/pop. Resyncing on
    /// every appearance makes that self-healing instead of a latent trap.
    func tabRootChrome(_ chrome: NavigationChromeVisibility, isPushed: Bool) -> some View {
        onAppear { chrome.isAtTabRoot = !isPushed }
            .onChange(of: isPushed) { _, pushed in chrome.isAtTabRoot = !pushed }
    }
}
