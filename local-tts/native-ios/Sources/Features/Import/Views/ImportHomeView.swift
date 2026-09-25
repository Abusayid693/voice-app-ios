import Hugeicons
import SwiftUI

/// The app's books-first Home. It owns navigation and Home-specific chrome;
/// `BookShelfView` owns the shelf content and its detail transition.
struct ImportHomeView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let app: AppEnvironment
    /// Driven by the Explore menu in `RootTabView`'s floating bar — Library,
    /// Voices and Tools are pushed here rather than mounted as peer tabs.
    @Binding var exploreDestination: ExploreDestination?
    /// RootTabView owns the PDF file importer (it's global, reachable from
    /// Add Books too) — forwarded into Tools' "Upload File" row so it
    /// triggers the exact same picker rather than a second one.
    let onAddBooks: () -> Void

    @State private var isSettingsPresented = false
    @State private var isAvatarPickerPresented = false
    @State private var openProject: SavedGeneration?
    @State private var isBookDetailPresented = false
    @State private var isReadingStatsPresented = false
    // Seeded with 7 zero-activity days so the strip never flashes empty
    // before the real one-shot load below finishes.
    @State private var recentActivity: [DayActivity] = ImportHomeView.emptyRecentDays()
    @AppStorage("bookShelf.selectedAvatar") private var selectedAvatarRawValue = ShelfAvatar.first.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            BookShelfView(
                library: libraryViewModel,
                pdfImports: app.pdfImports,
                readingStats: app.readingStats,
                isDetailPresented: $isBookDetailPresented
            ) { book in
                openProject = libraryViewModel.project(for: book.id)
            }
            // Home draws its own header controls instead of using the
            // navigation bar: a `ToolbarItem` renders through nav-bar
            // chrome (Liquid Glass on iOS 26, plus bar-button padding
            // around custom content), which neither the flat icon nor the
            // edge-to-edge avatar wants. Overlaid rather than inset, so
            // the shelf backdrop still runs to the top of the screen.
            .toolbar(.hidden, for: .navigationBar)
            // Applied before the controls so it sits under them: shelf rows
            // scrolling up soften into the top edge instead of running
            // straight into the icons.
            .overlay(alignment: .top) {
                ShelfTopBlur().ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) { headerControls }
            .sheet(isPresented: $isAvatarPickerPresented) {
                ShelfAvatarPickerSheet(selection: selectedAvatarBinding)
            }
            .navigationDestination(item: $openProject) { project in
                ChapterPlayerView(
                    project: project,
                    library: libraryViewModel,
                    chapterPlayer: app.chapterPlayer,
                    generationStore: app.generationStore,
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
            .tabRootChrome(
                app.navigationChrome,
                isPushed: openProject != nil || exploreDestination != nil || isReadingStatsPresented)
        }
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
        // Window-level (status bar, nav-bar material) counterpart to the
        // `.environment` above: light for the shelf, dark while an Explore
        // destination is on top of it.
        .preferredColorScheme(exploreDestination == nil ? .light : .dark)
    }

    @ViewBuilder
    private func exploreScreen(_ destination: ExploreDestination) -> some View {
        switch destination {
        case .library:
            LibraryTabView(viewModel: libraryViewModel, app: app)
        case .voices:
            VoicesTabView(packs: app.tts.packs, app: app)
        case .tools:
            ToolsView(libraryViewModel: libraryViewModel, app: app, onAddBooks: onAddBooks)
        }
    }

    /// Ghost controls floating over the shelf — no background of their own.
    /// Each keeps a 44pt tap target while its padding is set so the *visible*
    /// icon lands on the same 16pt margin a navigation bar would have used;
    /// that's why the two sides differ (the icons aren't the same size).
    private var headerControls: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                settingsButton
                recentActivityDots
                    // Grid is 28pt wide (3 × 6pt + 2 × 5pt gaps), plus its
                    // own 6pt tap-target padding on each side = 40pt total —
                    // indent it to sit centered under the 44pt icon above.
                    .padding(.leading, (44 - 40) / 2)
            }
            .padding(.leading, 16 - (44 - 25.3) / 2)
            Spacer(minLength: 0)
            shelfAvatarButton
                .padding(.trailing, 16 - (44 - 36.8) / 2)
        }
        .padding(.top, 4)
        // These are page content now, not bar chrome, so they fade with the
        // book detail rather than floating above it merely disabled.
        .opacity(isBookDetailPresented ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: isBookDetailPresented)
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
            Hugeicons.menu01.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(BookShelfPalette.primaryText)
                .frame(width: 25.3, height: 25.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Settings")
    }

    private var selectedAvatar: ShelfAvatar {
        ShelfAvatar(rawValue: selectedAvatarRawValue) ?? .first
    }

    private var selectedAvatarBinding: Binding<ShelfAvatar> {
        Binding(
            get: { selectedAvatar },
            set: { selectedAvatarRawValue = $0.rawValue })
    }

    @ViewBuilder
    private var shelfAvatarButton: some View {
        if let url = selectedAvatar.videoURL {
            Button {
                isAvatarPickerPresented = true
            } label: {
                LoopingVideoPlayerView(url: url, isPaused: reduceMotion)
                    .frame(width: 36.8, height: 36.8)
                    .clipShape(Circle())
                    .background(BookShelfPalette.background, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBookDetailPresented)
            .accessibilityLabel("Change avatar")
            .accessibilityHint("Opens a list of avatars to choose from")
        }
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
    return ImportHomeView(
        libraryViewModel: app.library, app: app, exploreDestination: .constant(nil),
        onAddBooks: {})
}
