import Hugeicons
import SwiftUI
import UniformTypeIdentifiers

/// A destination the Explore menu pushes onto Home's own navigation stack.
/// Home is the app's single root, not one of these — they were four peer
/// tabs before, each with its own stack; now Books *is* the app and the
/// rest are routes off it.
enum ExploreDestination: Hashable, CaseIterable, Identifiable {
    case library, voices, tools

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return "Library"
        case .voices: return "Voices"
        case .tools: return "Tools"
        }
    }

    var icon: HugeiconsAsset {
        switch self {
        case .library: return Hugeicons.folderLibrary
        case .voices: return Hugeicons.audioWave02
        case .tools: return Hugeicons.bolt
        }
    }
}

/// App shell: Home plus the floating Explore/Add Books bar. Everything the
/// Explore menu offers is pushed within Home's stack, so there is only one
/// mounted root and no tab state to preserve.
struct RootTabView: View {
    let app: AppEnvironment
    @ObservedObject private var navigationChrome: NavigationChromeVisibility
    // Observed explicitly (not read off `app`) per this app's re-render rule
    // — see AppEnvironment's own doc comment. Needed to show/hide the mini
    // player and drive the now-playing full-screen cover.
    @ObservedObject private var bookPlayer: BookAudioPlayer
    @State private var isExploreExpanded = false
    @State private var exploreDestination: ExploreDestination?
    @State private var isDocumentPickerPresented = false
    @State private var isNowPlayingPresented = false

    init(app: AppEnvironment) {
        self.app = app
        self.navigationChrome = app.navigationChrome
        self.bookPlayer = app.bookPlayer
    }

    var body: some View {
        GeometryReader { geometry in
            ImportHomeView(
                libraryViewModel: app.library,
                app: app,
                exploreDestination: $exploreDestination,
                onAddBooks: presentDocumentPicker)
                // Tapping anywhere on the page dismisses the open menu.
                // Clear rather than dimmed: the menu is a small floating
                // control, not a modal, so it shouldn't darken the shelf.
                .overlay {
                    if isExploreExpanded {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    isExploreExpanded = false
                                }
                            }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // One VStack, not two independent insets: the mini
                    // player and CustomTabBar share this single layout pass,
                    // same reasoning NavigationChromeVisibility's own doc
                    // comment gives for collapsing this app's tab-bar
                    // visibility down to one clock.
                    VStack(spacing: 12) {
                        if bookPlayer.activeRef != nil, !navigationChrome.isReaderOpen {
                            MiniPlayerBar(player: bookPlayer) { isNowPlayingPresented = true }
                                .padding(.horizontal, 19)
                                // The Explore menu expands ~210pt *upward*
                                // into this same space — fade the mini
                                // player out of its way rather than let the
                                // two collide.
                                .opacity(isExploreExpanded ? 0 : 1)
                                .allowsHitTesting(!isExploreExpanded)
                                .animation(.easeInOut(duration: 0.18), value: isExploreExpanded)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                // Closer to CustomTabBar underneath it than
                                // the VStack's own 12pt spacing alone —
                                // matches that bar's own `.offset(y: 25)`
                                // trick of sitting lower than its frame.
                                .offset(y: 30)
                        }
                        if navigationChrome.isAtTabRoot {
                            CustomTabBar(
                                isExploreExpanded: $isExploreExpanded,
                                safeAreaBottom: geometry.safeAreaInsets.bottom,
                                onSelect: open,
                                onAddBooks: presentDocumentPicker)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: navigationChrome.isAtTabRoot)
                .animation(.easeInOut(duration: 0.22), value: navigationChrome.isReaderOpen)
                .animation(.easeInOut(duration: 0.22), value: bookPlayer.activeRef)
        }
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                await app.pdfImports.importPDF(
                    from: url,
                    engine: .kokoroAne,
                    voiceName: app.tts.kokoroVoice)
            }
        }
        .fullScreenCover(isPresented: $isNowPlayingPresented) {
            NowPlayingView(player: bookPlayer) { isNowPlayingPresented = false }
        }
    }

    private func open(_ destination: ExploreDestination) {
        isExploreExpanded = false
        exploreDestination = destination
    }

    private func presentDocumentPicker() {
        isExploreExpanded = false
        Task { @MainActor in
            await Task.yield()
            isDocumentPickerPresented = true
        }
    }
}

#Preview {
    RootTabView(app: .preview())
}
