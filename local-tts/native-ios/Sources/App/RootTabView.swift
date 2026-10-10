import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable, CaseIterable {
    case shelf
    case tools
    case library
    case stats

    var title: String {
        switch self {
        case .shelf: return "My Shelf"
        case .stats: return "Stats"
        case .tools: return "Tools"
        case .library: return "Library"
        }
    }

    // System metadata for the hidden native tab bar. The visible custom row
    // uses code-native DesignSystem artwork below.
    var systemImage: String {
        switch self {
        case .shelf: return "books.vertical"
        case .stats: return "chart.bar.xaxis"
        case .tools: return "wrench.and.screwdriver"
        case .library: return "rectangle.stack"
        }
    }

    var icon: TabNavigationIconKind {
        switch self {
        case .shelf: return .shelf
        case .stats: return .stats
        case .tools: return .tools
        case .library: return .library
        }
    }

    var colorScheme: ColorScheme { self == .shelf ? .light : .dark }
    var background: Color { self == .shelf ? BookShelfPalette.background : .appBackground }
}

struct ReaderRoute: Identifiable, Hashable {
    let id = UUID()
    let project: SavedGeneration
    let initialPageIndex: Int?
    let initialSurfaceMode: ReaderSurfaceMode?
}

/// App-level tabs and presentation state. Each tab keeps its own navigation
/// stack while a reader push replaces the complete tab surface.
struct RootTabView: View {
    let app: AppEnvironment

    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var player: BookAudioPlayer

    @State private var selectedTab: AppTab = .shelf
    // Keep the tap event above the drawer's hosting boundary so replacing
    // its root content cannot reset the icon animation trigger.
    @State private var tabSelectionPulse = 0
    @State private var readerRoute: ReaderRoute?
    @State private var readerOwnerTab: AppTab?
    @State private var isSettingsPresented = false
    @State private var isDocumentPickerPresented = false
    @State private var isShelfDetailPresented = false
    @State private var statsRefreshToken = 0
    @ScaledMetric(relativeTo: .caption) private var tabRowHeight: CGFloat = 68

    init(app: AppEnvironment) {
        self.app = app
        _library = ObservedObject(wrappedValue: app.library)
        _player = ObservedObject(wrappedValue: app.player)
    }

    var body: some View {
        SettingsDrawerPresentation(
            viewModel: app.tts,
            previewPlayer: app.previewPlayer,
            isPresented: $isSettingsPresented,
            isEdgeSwipeEnabled: selectedTab == .shelf
                && readerRoute == nil
                && !isShelfDetailPresented
                && !isDocumentPickerPresented,
            content: tabs)
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [.pdf, .epub],
            allowsMultipleSelection: false,
            onCompletion: importDocument)
        .preferredColorScheme(selectedTab.colorScheme)
        .onChange(of: selectedTab) { _, tab in
            if tab == .stats { statsRefreshToken &+= 1 }
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab(AppTab.shelf.title, systemImage: AppTab.shelf.systemImage, value: AppTab.shelf) {
                tabRoot {
                    NavigationStack {
                        ImportHomeView(
                            libraryViewModel: library,
                            app: app,
                            isBookDetailPresented: $isShelfDetailPresented,
                            onPresentSettings: { isSettingsPresented = true },
                            onAddBooks: presentDocumentPicker,
                            onOpenReader: openReader)
                            .navigationDestination(item: readerBinding(for: .shelf)) {
                                readerDestination($0)
                            }
                    }
                }
            }

            Tab(AppTab.tools.title, systemImage: AppTab.tools.systemImage, value: AppTab.tools) {
                tabRoot {
                    NavigationStack {
                        ToolsView(
                            libraryViewModel: library,
                            app: app,
                            onAddBooks: presentDocumentPicker,
                            onOpenProject: { project in
                                openReader(
                                    ReaderRoute(
                                        project: project,
                                        initialPageIndex: nil,
                                        initialSurfaceMode: nil))
                            },
                            onImportDownloadedBook: { url, format in
                                await app.pdfImports.importBook(
                                    from: url,
                                    format: format,
                                    engine: .kokoroAne,
                                    voiceName: app.tts.kokoroVoice)
                            })
                            .navigationDestination(item: readerBinding(for: .tools)) {
                                readerDestination($0)
                            }
                    }
                }
            }

            Tab(AppTab.library.title, systemImage: AppTab.library.systemImage, value: AppTab.library) {
                tabRoot {
                    NavigationStack {
                        LibraryTabView(
                            viewModel: library,
                            onOpenProject: { project in
                                openReader(
                                    ReaderRoute(
                                        project: project,
                                        initialPageIndex: nil,
                                        initialSurfaceMode: nil))
                            })
                            .navigationDestination(item: readerBinding(for: .library)) {
                                readerDestination($0)
                            }
                    }
                }
            }

            Tab(AppTab.stats.title, systemImage: AppTab.stats.systemImage, value: AppTab.stats) {
                tabRoot {
                    ReadingStatsView(
                        readingStats: app.readingStats,
                        refreshToken: statsRefreshToken,
                        isActive: selectedTab == .stats)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .bottom) {
            if readerRoute == nil {
                bottomChrome
            }
        }
        // Apply this inside the drawer's UIHostingController as well as on
        // its outer representable, keeping chrome behind the rename keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var bottomChromeHeight: CGFloat {
        tabRowHeight + (player.activeRef == nil ? 0 : 70)
    }

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if player.activeRef != nil {
                MiniPlayerBar(player: player, onExpand: openPlayingBook)
                    .padding(.horizontal, 19)
                    .padding(.bottom, 10)
            }

            AppTabBar(selection: $selectedTab, selectionPulse: $tabSelectionPulse)
                .frame(height: tabRowHeight)
                .background {
                    // Anchor the band to the tab row, so the mini player
                    // never makes the blur taller. Only a short fade extends
                    // above the icons; the bottom reaches the home indicator.
                    TabBarProgressiveBackdrop(baseColor: selectedTab.background)
                        .padding(.top, -19.2)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
        }
        .environment(\.colorScheme, selectedTab.colorScheme)
        .allowsHitTesting(!isShelfDetailPresented)
        .accessibilityHidden(isShelfDetailPresented)
    }

    private func tabRoot<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if readerRoute == nil {
                    Color.clear
                        .frame(height: bottomChromeHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .toolbar(.hidden, for: .tabBar)
    }

    private func openReader(_ route: ReaderRoute) {
        readerOwnerTab = selectedTab
        readerRoute = route
    }

    private func readerBinding(for tab: AppTab) -> Binding<ReaderRoute?> {
        Binding(
            get: { readerOwnerTab == tab ? readerRoute : nil },
            set: { newValue in
                if let newValue {
                    readerOwnerTab = tab
                    readerRoute = newValue
                } else if readerOwnerTab == tab {
                    readerRoute = nil
                    readerOwnerTab = nil
                }
            })
    }

    private func readerDestination(_ route: ReaderRoute) -> some View {
        ChapterPlayerView(
            project: route.project,
            initialPageIndex: route.initialPageIndex,
            initialSurfaceMode: route.initialSurfaceMode,
            library: library,
            player: player,
            viewModel: app.tts,
            previewPlayer: app.previewPlayer,
            readingStats: app.readingStats)
            .toolbar(.hidden, for: .tabBar)
    }

    private func openPlayingBook() {
        guard
            let ref = player.activeRef,
            let project = library.project(for: ref.projectID)
        else { return }

        selectedTab = .shelf
        Task { @MainActor in
            await Task.yield()
            openReader(
                ReaderRoute(
                    project: project,
                    initialPageIndex: ref.pageIndex,
                    initialSurfaceMode: .audio))
        }
    }

    private func presentDocumentPicker() {
        Task { @MainActor in
            await Task.yield()
            isDocumentPickerPresented = true
        }
    }

    private func importDocument(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        Task {
            await app.pdfImports.importBook(
                from: url,
                engine: .kokoroAne,
                voiceName: app.tts.kokoroVoice)
        }
    }
}

/// Custom presentation over the retained system TabView. Each item is an
/// equally sized icon-and-label target, with the shared coral selection
/// and muted blue-gray resting state. Only the selection binding navigates.
private struct AppTabBar: View {
    @Binding var selection: AppTab
    @Binding var selectionPulse: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selection == tab

                Button {
                    selection = tab
                    selectionPulse &+= 1
                } label: {
                    VStack(spacing: 7) {
                        AnimatedTabIcon(
                            tab: tab,
                            isSelected: isSelected,
                            selectionPulse: selectionPulse)
                            .frame(height: 29)

                        Text(tab.title)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(
                        isSelected ? Color.tabSelected : unselectedColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 7)
    }

    private var unselectedColor: Color {
        .tabInactive(for: selection.colorScheme)
    }
}

/// Local presentation state animates the artwork only. The task runs for a
/// newly mounted selected icon as well as subsequent taps, so a tab/hosting
/// update cannot swallow the first activation. SwiftUI cancels the sequence
/// on a new trigger or disappearance; no delayed completion can replay it.
private struct AnimatedTabIcon: View {
    let tab: AppTab
    let isSelected: Bool
    let selectionPulse: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion: CGFloat = 0

    private struct Trigger: Equatable {
        let selected: Bool
        let pulse: Int
        let reduceMotion: Bool
    }

    var body: some View {
        TabNavigationIcon(kind: tab.icon, isSelected: isSelected)
            .frame(width: 26, height: 26)
            .scaleEffect(1 - 0.38 * motion)
            .rotationEffect(.degrees(flatTurn * Double(motion)))
            .rotation3DEffect(
                .degrees(tab == .shelf ? -50 * Double(motion) : 0),
                axis: (x: 0, y: 1, z: 0),
                anchor: .leading,
                perspective: 0.3)
            .task(
                id: Trigger(
                    selected: isSelected,
                    pulse: selectionPulse,
                    reduceMotion: reduceMotion)
            ) {
                await animateSelection()
            }
            .accessibilityHidden(true)
    }

    @MainActor
    private func animateSelection() async {
        guard isSelected, !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { motion = 0 }
            return
        }

        // Let a newly mounted icon render its neutral pose before starting.
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { return }

        withAnimation(.easeOut(duration: 0.12)) {
            motion = 1
        }

        do { try await Task.sleep(for: .milliseconds(120)) }
        catch { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.65)) {
            motion = 0
        }
    }

    private var flatTurn: Double {
        switch tab {
        case .shelf: return 0
        case .stats: return 0
        case .tools: return -18
        case .library: return -24
        }
    }
}

private struct TabBarProgressiveBackdrop: View {
    let baseColor: Color

    var body: some View {
        // No blur — the gradient's own stops carry the "progressive" read.
        // Only a thin sliver at the very top is fully clear; opacity climbs
        // sharply right after that so whatever's scrolling underneath the
        // tab icons is mostly covered, not just lightly tinted. A ~1.5x
        // pass on these stops read as too harsh; this is the ~1.1x tuning
        // that followed it instead.
        LinearGradient(
            stops: [
                .init(color: baseColor.opacity(0), location: 0),
                .init(color: baseColor.opacity(0.09), location: 0.06),
                .init(color: baseColor.opacity(0.66), location: 0.26),
                .init(color: baseColor.opacity(0.99), location: 0.55),
                .init(color: baseColor.opacity(1.0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview {
    RootTabView(app: .preview())
}
