import Foundation

/// Loads and aggregates reading sessions for the day orb carousel,
/// contribution graph, and day detail. The only `ObservableObject` in this
/// feature — everything below it (`ReadingStatsStore`/
/// `ReadingStatsStorageActor`) is plain/actor-isolated, so this is also the
/// only place `@Published` state exists here.
///
/// SwiftData has no raw `GROUP BY` (see `ReadingStatsStore`'s own note) —
/// this does the day-bucketing in Swift over rows already filtered/fetched
/// by the background actor.
@MainActor
final class ReadingStatsViewModel: ObservableObject {
    /// Every day in the rolling window, oldest first, today last. Seeded
    /// synchronously with zero-activity placeholders so the carousel/graph
    /// have their real, final item count on the very first frame — without
    /// this, `days` started `[]` and everything below it visibly popped in
    /// once the async `reload()` resolved.
    @Published private(set) var days: [DayActivity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var selectedDayDetail: DayDetail?
    /// The day orb carousel's centred day — settable directly (the carousel
    /// binds to it), unlike every other published property here. Defaults to
    /// today; `reload()` never resets it, so switching tabs away and back
    /// doesn't lose where the user was sliding.
    ///
    /// `didSet` is the one funnel every selection path (the carousel
    /// settling, a graph dot tap) already writes through — see
    /// `ContributionGraphView`'s own doc comment on why both exist only to
    /// move this one value — so it's the single correct place to fire the
    /// completed-day feedback, rather than duplicating the check at each
    /// call site. Assigning the initial value inside `init` below does not
    /// trigger this — Swift doesn't run property observers for a value set
    /// during its own type's initializer — so the feedback never fires on
    /// first launch/tab switch, only on a real user-driven change.
    @Published var selectedDay: Date {
        didSet {
            guard oldValue != selectedDay else { return }
            guard let activity = selectedDayActivity, activity.meetsGoal else { return }
            DayCompletionFeedback.play()
        }
    }
    /// Consecutive goal-met days ending at (or just before, if today hasn't
    /// met it yet) today. Computed purely over `days`, so it's capped by
    /// `windowMonths` — a 100-day streak inside a 3-month window reports as
    /// at most ~90. Widening the cap means widening the fetch; not done.
    @Published private(set) var currentStreak: Int = 0
    /// Dated history of goal edits — see `DailyGoalSchedule` for why this
    /// isn't one current number. Published so the editor's own displayed
    /// value tracks it.
    @Published private(set) var goalSchedule: DailyGoalSchedule

    private let store: ReadingStatsStore
    private let calendar: Calendar

    /// How far back the carousel and graph both reach. One number drives
    /// both, per the user's own request that they cover the same period.
    private static let windowMonths = 3

    init(store: ReadingStatsStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        goalSchedule = DailyGoalStore.load()
        selectedDay = calendar.startOfDay(for: Date())
        // Seeded here rather than as a property default so it can use the
        // *injected* calendar and the loaded schedule. It still runs before
        // any view reads `days`, which is the point of seeding at all: the
        // carousel and graph get their real, final item count on the first
        // frame instead of popping in once `reload()` resolves.
        days = Self.emptyWindowDays(calendar: calendar, schedule: goalSchedule)
    }

    /// The goal that applies to today — what the editor opens on and what
    /// the summary card shows alongside minutes read.
    var currentGoalMinutes: Int {
        goalSchedule.goalMinutes(on: calendar.startOfDay(for: Date()))
    }

    /// Records a new goal from today onward and re-derives everything that
    /// depends on it. Deliberately re-stamps the existing `days` rather than
    /// re-fetching: the sessions behind them haven't changed, only how each
    /// day is judged, so this stays synchronous and the page updates live
    /// underneath the (transparent) editor sheet.
    func setGoal(_ minutes: Int) {
        var schedule = goalSchedule
        schedule.setGoal(minutes, from: calendar.startOfDay(for: Date()))
        guard schedule != goalSchedule else { return }
        goalSchedule = schedule
        DailyGoalStore.save(schedule)

        days = days.map { activity in
            DayActivity(
                day: activity.day,
                listenedSeconds: activity.listenedSeconds,
                pagesCompleted: activity.pagesCompleted,
                goalSeconds: schedule.goalSeconds(on: activity.day))
        }
        currentStreak = Self.computeStreak(days, calendar: calendar)
    }

    /// The `DayActivity` for `selectedDay`, if that day falls inside the
    /// loaded window (it always should — `selectedDay` is only ever set to a
    /// day the carousel actually rendered).
    var selectedDayActivity: DayActivity? {
        days.first { calendar.isDate($0.day, inSameDayAs: selectedDay) }
    }

    /// Every day in the rolling window ending today. The range is
    /// calendar-based rather than a fixed day count, so month lengths and
    /// daylight-saving transitions remain correct.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        guard let range = Self.windowRange(calendar: calendar) else { return }
        let windowDays = Self.daysInWindow(calendar: calendar)
        guard !windowDays.isEmpty else { return }

        let sessions = await store.sessions(from: range.start, to: range.endExclusive)

        var listenedByDay: [Date: Double] = [:]
        var completedByDay: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            listenedByDay[day, default: 0] += session.listenedSeconds
            if session.pageCompleted {
                completedByDay[day, default: 0] += 1
            }
        }

        let activity = windowDays.map { day in
            DayActivity(
                day: day,
                listenedSeconds: listenedByDay[day] ?? 0,
                pagesCompleted: completedByDay[day] ?? 0,
                // Each day is judged against the goal that was in effect on
                // *that* day, not today's — see `DailyGoalSchedule`.
                goalSeconds: goalSchedule.goalSeconds(on: day))
        }
        days = activity
        currentStreak = Self.computeStreak(activity, calendar: calendar)
    }

    /// Placeholder shape for `days`' synchronous seed — every day of the
    /// rolling window at zero activity, so `reload()` swaps in new values
    /// for the exact same set of cells rather than changing the item count.
    private static func emptyWindowDays(
        calendar: Calendar, schedule: DailyGoalSchedule
    ) -> [DayActivity] {
        daysInWindow(calendar: calendar).map { day in
            DayActivity(
                day: day, listenedSeconds: 0, pagesCompleted: 0,
                goalSeconds: schedule.goalSeconds(on: day))
        }
    }

    private static func windowRange(
        calendar: Calendar, now: Date = Date()
    ) -> (start: Date, endExclusive: Date)? {
        let today = calendar.startOfDay(for: now)
        guard
            let start = calendar.date(byAdding: .month, value: -windowMonths, to: today),
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: today)
        else { return nil }
        return (start, endExclusive)
    }

    private static func daysInWindow(calendar: Calendar) -> [Date] {
        guard let range = windowRange(calendar: calendar) else { return [] }
        var days: [Date] = []
        var cursor = range.start
        while cursor < range.endExclusive {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Walks backward from the most recent day. Today not having met the
    /// goal yet doesn't break the streak — it's still in progress, not a
    /// miss — so counting starts at yesterday in that case; any other day
    /// short of the goal ends the count immediately.
    private static func computeStreak(_ days: [DayActivity], calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        var streak = 0
        var index = days.count - 1
        if !days[index].meetsGoal {
            index -= 1
        }
        while index >= 0, days[index].meetsGoal {
            streak += 1
            index -= 1
        }
        return streak
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
}
