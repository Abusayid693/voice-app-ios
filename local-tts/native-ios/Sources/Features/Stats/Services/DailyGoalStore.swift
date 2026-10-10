import Foundation

/// Persists `DailyGoalSchedule` in `UserDefaults`, matching how the app's
/// other user preferences are stored (see `TTSViewModel`'s default-voice
/// key). Deliberately not a second SwiftData `@Model` alongside
/// `ReadingSession`: this is a handful of preference values read
/// synchronously while building the page, not queryable history, and adding
/// an entity would mean a schema migration for the stats store.
enum DailyGoalStore {
    private static let defaultsKey = "readingStats.dailyGoalChanges"

    static func load(defaults: UserDefaults = .standard) -> DailyGoalSchedule {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let changes = try? JSONDecoder().decode([DailyGoalChange].self, from: data)
        else {
            // No stored edits — every day resolves to the default goal,
            // which is what this app shipped as a fixed constant before.
            return DailyGoalSchedule()
        }
        return DailyGoalSchedule(changes: changes)
    }

    static func save(_ schedule: DailyGoalSchedule, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(schedule.changes) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
