import SwiftUI

/// Whether `RootTabView`'s custom bottom bar (`CustomTabBar` — the Explore
/// control and Add Books) should be visible — true only while Home's
/// `NavigationStack` sits at its root screen, false the moment anything is
/// pushed within it (a reader page, or an Explore destination and whatever
/// that destination pushes in turn).
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
/// Driven by Home's own push-triggering `@State` (`openProject`,
/// `exploreDestination`) via `.onChange`, not by the pushed screens
/// themselves. Pushing a new screen in a `NavigationStack` also fires the
/// *previous* screen's `.onDisappear`, so two screens independently
/// toggling one shared flag on appear/disappear can race and land wrong
/// depending on ordering. The root's own state doesn't have that problem:
/// it's one value, changed in one place, and stays non-nil for as long as
/// anything is pushed under it however many levels deep — so reading it
/// straight from the presenter is both simpler and race-free. That's also
/// why a pushed Explore destination (Library, Voices) must *not* apply this
/// itself: Home already covers everything below it, and a second writer
/// would put the bar back over a pushed screen.
@MainActor
final class NavigationChromeVisibility: ObservableObject {
    @Published var isAtTabRoot = true
}

extension View {
    /// Keeps `chrome.isAtTabRoot` in sync with whether Home currently has
    /// something pushed. `.onAppear` (not just `.onChange`)
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
