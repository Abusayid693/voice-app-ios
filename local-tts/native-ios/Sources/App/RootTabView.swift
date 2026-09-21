import Hugeicons
import SwiftUI

enum RootTab: Hashable, CaseIterable, Identifiable {
    case home, library, tools, voices

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .tools: return "Tools"
        case .voices: return "Voices"
        }
    }

    var icon: HugeiconsAsset {
        switch self {
        case .home: return Hugeicons.home01
        case .library: return Hugeicons.folderLibrary
        case .tools: return Hugeicons.bolt
        case .voices: return Hugeicons.audioWave02
        }
    }
}

/// App shell: 4 tabs (Home/Library/Tools/Voices) + a "+" quick-action
/// button, all in one custom bottom bar (`CustomTabBar`) rather than the
/// native `TabView` tab bar + a separately-floating button. That split
/// used to exist — the native tab bar hid on pushed screens via
/// `.toolbar(.hidden, for: .tabBar)` (UIKit-transition-timed) while the
/// "+" button hid via our own `NavigationChromeVisibility` + `.animation`
/// — and the two, being driven by different clocks, kept visibly
/// desyncing (the "+" button appearing before the real tab bar finished
/// reappearing). One custom bar means one `.transition`/`.animation`
/// governs the whole thing's visibility, with nothing left to desync
/// against.
///
/// Each tab root still owns its own `NavigationStack` and push state
/// exactly as before — only the chrome around them changed. All 4 are
/// kept unconditionally instantiated in `tabContent` (never `if
/// selectedTab == tab { ... }`, which would tear down and rebuild a tab's
/// `@State` on every switch) and shown/hidden via `.opacity` +
/// `.allowsHitTesting` + `.accessibilityHidden`, reproducing the
/// "each tab remembers where you left it" behavior `TabView` gave for
/// free. Tapping "+" opens `QuickActionsSheet` (the same 8 actions as
/// Home's action grids); only "Write text" does anything, by reusing
/// Home's existing `isWriteTextPresented` pipeline rather than building a
/// second one — see the `.sheet`'s `onDismiss` below.
///
/// Home now hosts the consumer-facing `ImportHomeView` (previously the
/// separate "Import" tab).
struct RootTabView: View {
    // This shell reads nothing off any of these itself — it only hands each
    // tab root the objects that root actually observes. A plain `let` of a
    // non-observable container (see AppEnvironment), so it subscribes to
    // nothing.
    let app: AppEnvironment
    // The one piece of `app` this shell genuinely reacts to (hides
    // CustomTabBar on pushed screens) — taken as its own @ObservedObject,
    // same as any other view that needs to observe something rather than
    // just forward it. See NavigationChromeVisibility's doc comment.
    @ObservedObject private var navigationChrome: NavigationChromeVisibility
    @State private var selectedTab: RootTab = .home
    @State private var isQuickActionsPresented = false
    // Set the instant "Write text" is chosen in QuickActionsSheet, but only
    // acted on once this sheet's own onDismiss fires — mirrors
    // ImportHomeView's own pendingProjectID, which exists for the same
    // reason: two presentation-affecting writes in one SwiftUI transaction
    // can silently drop one of them.
    @State private var pendingWriteText = false

    init(app: AppEnvironment) {
        self.app = app
        self.navigationChrome = app.navigationChrome
    }

    var body: some View {
        GeometryReader { geometry in
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if navigationChrome.isAtTabRoot {
                        CustomTabBar(
                            selectedTab: $selectedTab, safeAreaBottom: geometry.safeAreaInsets.bottom,
                            onPlusTapped: { isQuickActionsPresented = true }
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.default, value: navigationChrome.isAtTabRoot)
        }
        .sheet(
            isPresented: $isQuickActionsPresented,
            onDismiss: {
                if pendingWriteText {
                    pendingWriteText = false
                    selectedTab = .home
                    app.tts.isWriteTextPresented = true
                }
            }
        ) {
            QuickActionsSheet { action in
                if action == .writeText {
                    pendingWriteText = true
                }
                isQuickActionsPresented = false
            }
        }
    }

    // All 4 unconditionally instantiated (never `if selectedTab == tab`),
    // toggled only by opacity/hit-testing/accessibility — see this type's
    // own doc comment for why.
    private var tabContent: some View {
        ZStack {
            ImportHomeView(
                viewModel: app.tts, libraryViewModel: app.library, packs: app.tts.packs, app: app
            )
            .opacity(selectedTab == .home ? 1 : 0)
            .allowsHitTesting(selectedTab == .home)
            .accessibilityHidden(selectedTab != .home)

            LibraryTabView(viewModel: app.library, app: app)
                .opacity(selectedTab == .library ? 1 : 0)
                .allowsHitTesting(selectedTab == .library)
                .accessibilityHidden(selectedTab != .library)

            PlaceholderTabView(title: "Tools")
                .opacity(selectedTab == .tools ? 1 : 0)
                .allowsHitTesting(selectedTab == .tools)
                .accessibilityHidden(selectedTab != .tools)

            VoicesTabView(viewModel: app.voiceClone, app: app)
                .opacity(selectedTab == .voices ? 1 : 0)
                .allowsHitTesting(selectedTab == .voices)
                .accessibilityHidden(selectedTab != .voices)
        }
    }
}

#Preview {
    RootTabView(app: .preview())
}
