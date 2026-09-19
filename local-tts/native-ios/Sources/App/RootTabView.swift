import LucideSwift
import SwiftUI

enum RootTab: Hashable {
    case home, library, tools, voices
}

/// Rasterizes a Lucide icon to a template `Image`, for use as a `.tabItem`
/// icon only.
///
/// `LucideIcon` renders as a `ZStack` of stroked/filled vector `Shape`s, not
/// a plain `Image`. `.tabItem` builds each `UITabBarItem` through UIKit's own
/// image-extraction pipeline, which reliably rasterizes `Image` content but
/// not arbitrary custom SwiftUI views — on device this silently produced
/// blank tab bar icons, even though the exact same `LucideIcon` renders fine
/// as a toolbar button or inline icon elsewhere (those never go through this
/// extraction). Pre-rendering to a real `UIImage` and marking it
/// `.alwaysTemplate` sidesteps it: UIKit tints the bitmap itself
/// (selected/unselected color) exactly like an SF Symbol, instead of trying
/// to snapshot the live shape.
@MainActor
private func tabIcon(_ name: LucideIconName, size: CGFloat = 24) -> Image {
    let renderer = ImageRenderer(content: LucideIcon(name, size: size, color: .black))
    renderer.scale = UIScreen.main.scale
    guard let uiImage = renderer.uiImage?.withRenderingMode(.alwaysTemplate) else {
        return Image(systemName: "circle")
    }
    return Image(uiImage: uiImage)
}

/// App shell: 4 tabs (Home/Library/Tools/Voices) plus a floating "+" action
/// button, deliberately not a 5th tab — a separate, always-visible quick
/// action rather than a routed screen. Tapping it opens `QuickActionsSheet`
/// (the same 8 actions as Home's action grids); only "Write text" does
/// anything, by reusing Home's existing `isWriteTextPresented` pipeline
/// rather than building a second one — see `addButton`'s doc comment.
///
/// Home now hosts the consumer-facing `ImportHomeView` (previously the
/// separate "Import" tab).
struct RootTabView: View {
    // This shell reads nothing off any of these itself — it only hands each
    // tab root the objects that root actually observes. A plain `let` of a
    // non-observable container (see AppEnvironment), so it subscribes to
    // nothing.
    let app: AppEnvironment
    @State private var selectedTab: RootTab = .home
    @State private var isQuickActionsPresented = false
    // Set the instant "Write text" is chosen in QuickActionsSheet, but only
    // acted on once this sheet's own onDismiss fires (see addButton) —
    // mirrors ImportHomeView's own pendingProjectID, which exists for the
    // same reason: two presentation-affecting writes in one SwiftUI
    // transaction can silently drop one of them.
    @State private var pendingWriteText = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                ImportHomeView(
                    viewModel: app.tts, libraryViewModel: app.library, packs: app.tts.packs,
                    app: app
                )
                .tabItem { Label(title: { Text("Home") }, icon: { tabIcon(.house) }) }
                .tag(RootTab.home)

                LibraryTabView(viewModel: app.library, app: app)
                    .tabItem { Label(title: { Text("Library") }, icon: { tabIcon(.library) }) }
                    .tag(RootTab.library)

                PlaceholderTabView(title: "Tools")
                    .tabItem { Label(title: { Text("Tools") }, icon: { tabIcon(.wrench) }) }
                    .tag(RootTab.tools)

                VoicesTabView(viewModel: app.voiceClone)
                    .tabItem { Label(title: { Text("Voices") }, icon: { tabIcon(.audioWaveform) }) }
                    .tag(RootTab.voices)
            }

            addButton
        }
    }

    private var addButton: some View {
        Button {
            isQuickActionsPresented = true
        } label: {
            LucideIcon(.plus, size: 22, color: Color.primaryButtonText)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.primaryButtonBackground))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .padding(.trailing, 20)
        // Clears the system tab bar (~49pt + safe-area inset) so the button
        // floats just above it, not overlapping the tab labels.
        .padding(.bottom, 75)
        // Deferred to onDismiss, not set alongside isQuickActionsPresented
        // = false in onSelect — ImportHomeView's fullScreenCover lives on
        // a sibling tab still in the same window's presentation chain as
        // this sheet, so presenting it before this sheet's own dismissal
        // transaction finishes risks the same silently-dropped-write
        // problem ImportHomeView's pendingProjectID already exists to
        // avoid. selectedTab is a plain @State write (not a presentation),
        // so it's safe to bundle in here alongside isWriteTextPresented.
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
}

#Preview {
    RootTabView(app: .preview())
}
