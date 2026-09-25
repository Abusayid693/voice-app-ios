import Foundation

/// Loads and aggregates reading sessions for the contribution graph + day
/// detail. The only `ObservableObject` in this feature — everything below
/// it (`ReadingStatsStore`/`ReadingStatsStorageActor`) is plain/actor-
/// isolated, so this is also the only place `@Published` state exists here.
///
/// SwiftData has no raw `GROUP BY` (see `ReadingStatsStore`'s own note) —
/// this does the day-bucketing in Swift over rows already filtered/fetched
/// by the background actor.
@MainActor
final class ReadingStatsViewModel: ObservableObject {
    /// Grouped 7 per row (Sunday-first) — a layout `ContributionGraphView`
    /// no longer renders directly (it now lays out a flat 18-per-row grid),
    /// but this shape is kept as the fetch/aggregation boundary since it's
    /// still a correct, order-preserving source: the view flattens it back
    /// into a single chronological list. `nil` cells are padding before
    /// Jan 1 or after Dec 31 of the current year, keeping every row a full
    /// 7 days; the view drops those when it flattens.
    @Published private(set) var weeks: [[DayActivity?]] = []
    @Published private(set) var isLoading = false
    @Published private(set) var selectedDayDetail: DayDetail?
    /// Seconds listened today — drives the half-circle goal gauge. Read
    /// straight off the same `reload()` pass that builds `weeks` rather than
    /// a separate fetch, since today is always the last real day in range.
    @Published private(set) var todayListenedSeconds: Double = 0

    private let store: ReadingStatsStore
    private let calendar: Calendar

    init(store: ReadingStatsStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func loadIfNeeded() async {
        guard weeks.isEmpty else { return }
        await reload()
    }

    /// Every day of the current calendar year, January 1 through December
    /// 31 — not a rolling window. Days later in the year than today have no
    /// sessions yet, so they fall out naturally as empty (level 0) dots,
    /// same convention as Book Shelf's own current-week teaser
    /// (`ImportHomeView.recentActivityDots`).
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let year = calendar.component(.year, from: Date())
        guard
            let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
            let yearEndExclusive = calendar.date(
                from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return }

        let sessions = await store.sessions(from: yearStart, to: yearEndExclusive)

        var listenedByDay: [Date: Double] = [:]
        var completedByDay: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            listenedByDay[day, default: 0] += session.listenedSeconds
            if session.pageCompleted {
                completedByDay[day, default: 0] += 1
            }
        }

        var days: [DayActivity] = []
        var cursor = yearStart
        while cursor < yearEndExclusive {
            days.append(
                DayActivity(
                    day: cursor,
                    listenedSeconds: listenedByDay[cursor] ?? 0,
                    pagesCompleted: completedByDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        weeks = Self.groupIntoWeeks(days, calendar: calendar)
        todayListenedSeconds = listenedByDay[calendar.startOfDay(for: Date())] ?? 0
    }

    func selectDay(_ day: Date) async {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let sessions = await store.sessions(from: dayStart, to: dayEnd)

        let byProject = Dictionary(grouping: sessions, by: \.projectID)
        let rows =
            byProject
            .map { projectID, projectSessions -> DayDetailBookRow in
                DayDetailBookRow(
                    projectID: projectID,
                    bookTitle: projectSessions.first?.bookTitle ?? "Untitled",
                    pagesCompleted: projectSessions.filter(\.pageCompleted).count,
                    listenedSeconds: projectSessions.reduce(0) { $0 + $1.listenedSeconds },
                    voiceNames: Array(Set(projectSessions.map(\.voiceName))).sorted())
            }
            .sorted { $0.listenedSeconds > $1.listenedSeconds }

        selectedDayDetail = DayDetail(
            day: dayStart,
            totalListenedSeconds: sessions.reduce(0) { $0 + $1.listenedSeconds },
            totalPagesCompleted: sessions.filter(\.pageCompleted).count,
            books: rows)
    }

    func clearSelectedDay() {
        selectedDayDetail = nil
    }

    /// Pads the front so the first real day lands on its correct weekday
    /// column, then chunks into weeks of 7 — every returned week has
    /// exactly 7 entries, `nil` where there's no day (before the range
    /// starts, or nothing to show past the last full week).
    private static func groupIntoWeeks(
        _ days: [DayActivity], calendar: Calendar
    ) -> [[DayActivity?]] {
        guard let firstDay = days.first?.day else { return [] }
        // .weekday is 1-based, Sunday = 1 — this many empty cells precede
        // the first real day in its week.
        let leadingPadding = calendar.component(.weekday, from: firstDay) - 1
        var padded: [DayActivity?] = Array(repeating: nil, count: leadingPadding)
        padded.append(contentsOf: days.map { $0 })
        while padded.count % 7 != 0 {
            padded.append(nil)
        }
        return stride(from: 0, to: padded.count, by: 7).map { start in
            Array(padded[start..<start + 7])
        }
    }
}
