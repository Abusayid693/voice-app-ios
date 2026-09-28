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

    var id: Date { day }

    /// 0 = no activity, 1...4 = increasing — the contribution graph's
    /// 5-step color ramp (see `Colors.statsIntensity0...4`).
    var intensityLevel: Int {
        switch listenedSeconds {
        case ..<1: return 0
        case ..<300: return 1  // < 5 min
        case ..<900: return 2  // 5–15 min
        case ..<1800: return 3  // 15–30 min
        default: return 4  // 30+ min
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
