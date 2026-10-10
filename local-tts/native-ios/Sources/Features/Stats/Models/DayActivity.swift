import Foundation

/// One day's aggregate — derived at read time by `ReadingStatsViewModel`
/// from raw `ReadingSession` rows, never stored. `day` is always a
/// `Calendar.startOfDay` value.
struct DayActivity: Identifiable, Equatable {
    let day: Date
    let listenedSeconds: Double
    /// Count of sessions that finished this day, not distinct pages —
    /// re-reading a page the same day counts twice here, matching "how much
    /// did I do today" rather than "how many pages have I ever finished".
    let pagesCompleted: Int
    /// The goal in effect **on this day**, resolved from
    /// `DailyGoalSchedule` when the day is built — per-day rather than a
    /// shared constant, so raising today's goal doesn't retroactively
    /// un-complete last month's days. Shared by the streak (a day only
    /// counts toward it once met), the orb's fill, and `intensityLevel`
    /// below, so none of the three can drift apart for a given day.
    let goalSeconds: Double

    var id: Date { day }

    var meetsGoal: Bool { listenedSeconds >= goalSeconds }

    /// 0...1 progress toward this day's goal — drives the day orb's fill.
    var goalProgress: Double { min(listenedSeconds / goalSeconds, 1) }

    /// 0 = no activity, 1...4 = increasing — the contribution graph's
    /// 5-step color ramp (see `Colors.statsIntensity0...4`).
    ///
    /// The thresholds are **fractions of the day's own goal**, not fixed
    /// minute counts. They have to be: with absolute cutoffs, a goal below
    /// 15 minutes would order the cases wrong (a 12-minute day at a
    /// 10-minute goal would match a `< 15 min` bucket before ever reaching
    /// the goal arm, reporting "partial" for a day it had actually
    /// completed). At the default 30-minute goal these land on exactly the
    /// 5/15/30-minute steps this replaced, so nothing shifts for anyone who
    /// never edits the goal. The top bucket is the goal itself, so a
    /// full-intensity dot and a filled day orb always agree.
    var intensityLevel: Int {
        guard listenedSeconds >= 1 else { return 0 }
        guard goalSeconds > 0 else { return 4 }
        switch listenedSeconds / goalSeconds {
        case ..<(1.0 / 6.0): return 1  // < 5 min of a 30-min goal
        case ..<0.5: return 2  // 5–15 min of a 30-min goal
        case ..<1: return 3  // 15–30 min of a 30-min goal
        default: return 4  // goal met
        }
    }
}

/// One book's rows within a selected day's detail.
struct DayDetailBookRow: Identifiable {
    let projectID: UUID
    let bookTitle: String
    let pagesCompleted: Int
    let listenedSeconds: Double
    let voiceNames: [String]

    var id: UUID { projectID }
}

struct DayDetail: Identifiable {
    let day: Date
    let totalListenedSeconds: Double
    let totalPagesCompleted: Int
    let books: [DayDetailBookRow]

    var id: Date { day }
}
