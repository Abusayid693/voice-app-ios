import Hugeicons
import SwiftUI
import UniformTypeIdentifiers

/// The app's books-first Home. It owns navigation and Home-specific chrome;
/// `BookShelfView` owns the shelf content and its detail transition.
struct ImportHomeView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var player: BookAudioPlayer
    let app: AppEnvironment

    @State private var isSettingsPresented = false
    @State private var isExploreExpanded = false
    @State private var exploreDestination: ExploreDestination?
    @State private var isDocumentPickerPresented = false
    @State private var openProject: SavedGeneration?
    /// Which surface the pending push should open on — nil means "use the
    /// reader's stored preference".
    @State private var openSurfaceMode: ReaderSurfaceMode?
    /// Page to open at, when the push came from somewhere that knows one
    /// (the mini player). Nil falls back to the project's saved position.
    @State private var openPageIndex: Int?
    @State private var isBookDetailPresented = false
    @State private var isReadingStatsPresented = false
    /// Stable device inset so keyboard height never becomes chrome padding.
    @State private var deviceBottomInset: CGFloat? = nil
    // Seeded with 7 zero-activity days so the strip never flashes empty
    // before the real one-shot load below finishes.
    @State private var recentActivity: [DayActivity] = ImportHomeView.emptyRecentDays()

    init(libraryViewModel: LibraryViewModel, app: AppEnvironment) {
        self.libraryViewModel = libraryViewModel
        self.app = app
        self._player = ObservedObject(wrappedValue: app.player)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                shelfRoot(
                    safeAreaBottom: deviceBottomInset ?? geometry.safeAreaInsets.bottom
                )
                .onAppear {
                    if deviceBottomInset == nil {
                        deviceBottomInset = geometry.safeAreaInsets.bottom
                    }
                }
            }
            .navigationDestination(item: $openProject) { project in
                ChapterPlayerView(
                    project: project,
                    initialPageIndex: openPageIndex,
                    initialSurfaceMode: openSurfaceMode,
                    library: libraryViewModel,
                    player: app.player,
                    viewModel: app.tts,
                    previewPlayer: app.previewPlayer,
                    readingStats: app.readingStats)
            }
            .navigationDestination(item: $exploreDestination) { destination in
                exploreScreen(destination)
                    // Every Explore destination is dark while the shelf
                    // below it is light. Scoping the scheme to the pushed
                    // content is the reliable lever here — `.environment`
                    // is read top-down by the subtree that sets it, unlike
                    // `.preferredColorScheme`, which is a presentation-wide
                    // preference an ancestor can override.
                    .environment(\.colorScheme, .dark)
            }
            .navigationDestination(isPresented: $isReadingStatsPresented) {
                // Explicit even though Home's own window scheme is already
                // light here (isReadingStatsPresented doesn't touch
                // exploreDestination) — same convention as the Explore
                // destinations above: the push site states the theme
                // rather than a pushed screen inheriting it implicitly.
                ReadingStatsView(readingStats: app.readingStats)
                    .environment(\.colorScheme, .light)
            }
        }
        // Keep shelf chrome behind the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task { await loadRecentActivity() }
        // Reload when a reader page is closed — that's the natural moment
        // a new session may have just been recorded for today.
        .onChange(of: openProject) { oldValue, newValue in
            guard oldValue != nil, newValue == nil else { return }
            Task { await loadRecentActivity() }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(viewModel: app.tts)
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
        // Window-level (status bar, nav-bar material) counterpart to the
        // `.environment` above: light for the shelf, dark while an Explore
        // destination is on top of it.
        .preferredColorScheme(exploreDestination == nil ? .light : .dark)
    }

    /// Keeps Shelf and its fixed chrome on one navigation surface.
    private func shelfRoot(safeAreaBottom: CGFloat) -> some View {
        BookShelfView(
            library: libraryViewModel,
            importShelf: app.pdfImports.shelfStore,
            pdfImports: app.pdfImports,
            readingStats: app.readingStats,
            isDetailPresented: $isBookDetailPresented,
            onOpenBook: { book in
                openSurfaceMode = nil
                openProject = libraryViewModel.project(for: book.id)
            },
            onListen: { book in
                // Reuse the reader route and land on its audio surface.
                openSurfaceMode = .audio
                openPageIndex = nil
                openProject = libraryViewModel.project(for: book.id)
            })
        // Overlaying the custom header preserves status-bar artwork.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            ShelfTopBlur().ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .top) { headerControls }
        // Keep Explore dismissal on the same root as its controls.
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
        // Reserve scroll room separately because visible safe-area insets follow the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: shelfBottomChromeHeight(safeAreaBottom: safeAreaBottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // The visible controls stay on the device edge and are covered by the keyboard.
        .overlay(alignment: .bottom) {
            shelfBottomChrome(safeAreaBottom: safeAreaBottom)
                .padding(.bottom, safeAreaBottom)
        }
    }

    private func shelfBottomChromeHeight(safeAreaBottom: CGFloat) -> CGFloat {
        // Mirrors CustomTabBar and the optional 60pt player plus 12pt spacing.
        let tabBarHeight = 69 + max(safeAreaBottom - 31, 8)
        return tabBarHeight + (player.activeRef == nil ? 0 : 72)
    }

    private func shelfBottomChrome(safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: 12) {
            if player.activeRef != nil {
                MiniPlayerBar(player: player, onExpand: openPlayingBook)
                    .padding(.horizontal, 19)
                    // Retain player identity while Explore uses this space.
                    .opacity(isExploreExpanded ? 0 : 1)
                    .allowsHitTesting(!isExploreExpanded)
                    .animation(.easeInOut(duration: 0.18), value: isExploreExpanded)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .offset(y: 30)
            }

            CustomTabBar(
                isExploreExpanded: $isExploreExpanded,
                safeAreaBottom: safeAreaBottom,
                onSelect: open,
                onAddBooks: presentDocumentPicker)
        }
        .animation(.easeInOut(duration: 0.22), value: player.activeRef)
    }

    /// Reopens the active project through Home's route state.
    private func openPlayingBook() {
        guard
            let ref = player.activeRef,
            let project = libraryViewModel.project(for: ref.projectID)
        else { return }
        openPageIndex = ref.pageIndex
        openSurfaceMode = .audio
        openProject = project
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

    @ViewBuilder
    private func exploreScreen(_ destination: ExploreDestination) -> some View {
        switch destination {
        case .library:
            LibraryTabView(viewModel: libraryViewModel, app: app)
        case .voices:
            VoicesTabView(packs: app.tts.packs, app: app)
        case .tools:
            ToolsView(
                libraryViewModel: libraryViewModel,
                app: app,
                onAddBooks: presentDocumentPicker)
        }
    }

    /// Ghost controls floating over the shelf with 44pt tap targets.
    private var headerControls: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsButton
                .padding(.leading, 16 - (44 - 25.3) / 2)
            Spacer(minLength: 0)
            recentActivityDots
                // The visible 28pt grid lands on the standard 16pt margin.
                .padding(.trailing, 10)
        }
        .padding(.top, 4)
    }

    /// A 7-dot grid for the current week (Monday first), 3 per row wrapping
    /// to a 4th partial row, reading left-to-right then top-to-bottom, same
    /// chronological convention as `ContributionGraphView`. A day later in
    /// the week than today just has no sessions yet, so it renders as an
    /// empty dot rather than needing to be hidden. Tapping it opens the full
    /// `ReadingStatsView` route. Intensity reuses `Color.statsIntensity` —
    /// the same ramp `ContributionGraphView` draws its dots from, so this
    /// teaser and the full graph it opens into read as one system.
    private var recentActivityDots: some View {
        Button {
            isReadingStatsPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(recentActivity.chunked(into: 3).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        ForEach(row) { day in
                            Circle()
                                .fill(Color.statsIntensity(level: day.intensityLevel))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Reading stats")
        .accessibilityHint("Opens this week's listening activity")
    }

    /// Monday of the week containing `Date()` — deliberately computed
    /// rather than relying on `calendar.firstWeekday`, which follows the
    /// device's region (e.g. Sunday-first in the US) and would silently
    /// reorder this Mon…Sun strip per-locale.
    private static func currentWeekStart(calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: Date())
        // `.weekday` is 1-based, Sunday = 1: (weekday + 5) % 7 maps
        // Mon->0 ... Sun->6, i.e. days since this week's Monday.
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
    }

    private static func emptyRecentDays(calendar: Calendar = .current) -> [DayActivity] {
        let weekStart = currentWeekStart(calendar: calendar)
        return (0..<7).compactMap { offset -> DayActivity? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart)
            else { return nil }
            return DayActivity(day: day, listenedSeconds: 0, pagesCompleted: 0)
        }
    }

    /// This calendar week, Monday through Sunday — not a rolling last-7-days
    /// window. Days later in the week than today have no sessions yet, so
    /// they fall out naturally as empty (level 0) dots rather than needing
    /// special-casing.
    private func loadRecentActivity() async {
        let calendar = Calendar.current
        let weekStart = Self.currentWeekStart(calendar: calendar)
        guard let rangeEndExclusive = calendar.date(byAdding: .day, value: 7, to: weekStart)
        else { return }

        let sessions = await app.readingStats.sessions(from: weekStart, to: rangeEndExclusive)
        var listenedByDay: [Date: Double] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            listenedByDay[day, default: 0] += session.listenedSeconds
        }

        var days: [DayActivity] = []
        var cursor = weekStart
        for _ in 0..<7 {
            days.append(
                DayActivity(day: cursor, listenedSeconds: listenedByDay[cursor] ?? 0, pagesCompleted: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        recentActivity = days
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Hugeicons.menu02.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(BookShelfPalette.primaryText.opacity(0.7))
                .frame(width: 25.3, height: 25.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Settings")
    }
}

extension Array {
    /// Splits into consecutive groups of at most `size`, last group short if
    /// the count doesn't divide evenly. Used only to wrap `recentActivityDots`
    /// into rows.
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return ImportHomeView(libraryViewModel: app.library, app: app)
}
