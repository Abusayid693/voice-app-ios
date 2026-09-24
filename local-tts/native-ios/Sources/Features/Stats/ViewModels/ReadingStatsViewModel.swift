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
    /// One column per week, one row per weekday (Sunday-first) — `nil`
    /// cells are padding before the tracked range started or after today,
    /// keeping every column a full 7 days for a regular grid.
    @Published private(set) var weeks: [[DayActivity?]] = []
    @Published private(set) var isLoading = false
    @Published private(set) var selectedDayDetail: DayDetail?

    private let store: ReadingStatsStore
    private let calendar: Calendar
    // ~1 year, GitHub-style.
    private let weeksToShow = 53

    init(store: ReadingStatsStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func loadIfNeeded() async {
        guard weeks.isEmpty else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let today = calendar.startOfDay(for: Date())
        guard
            let rangeStart = calendar.date(
                byAdding: .day, value: -(weeksToShow * 7 - 1), to: today),
            let rangeEndExclusive = calendar.date(byAdding: .day, value: 1, to: today)
        else { return }

        let sessions = await store.sessions(from: rangeStart, to: rangeEndExclusive)

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
        var cursor = rangeStart
        while cursor <= today {
            days.append(
                DayActivity(
                    day: cursor,
                    listenedSeconds: listenedByDay[cursor] ?? 0,
                    pagesCompleted: completedByDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        weeks = Self.groupIntoWeeks(days, calendar: calendar)
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
