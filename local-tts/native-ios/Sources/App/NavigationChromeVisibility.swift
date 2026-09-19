import SwiftUI

/// Whether the app's root chrome (tab bar, floating "+" button) should be
/// visible — true only while every tab's own `NavigationStack` sits at its
/// root screen (Home/Library/Tools/Voices), false the moment anything is
/// pushed within any of them.
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
///
/// The system tab bar itself doesn't need this — `.toolbar(.hidden, for:
/// .tabBar)` on each pushed screen already handles that natively. This
/// object exists only for the custom "+" button, which isn't part of the
/// real tab bar and doesn't respond to that modifier.
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
    /// visible "+" button short of triggering another push/pop. Resyncing
    /// on every appearance makes that self-healing instead of a latent trap.
    func tabRootChrome(_ chrome: NavigationChromeVisibility, isPushed: Bool) -> some View {
        onAppear { chrome.isAtTabRoot = !isPushed }
            .onChange(of: isPushed) { _, pushed in chrome.isAtTabRoot = !pushed }
    }
}
