import Foundation

/// One change to the daily reading goal, in effect from `effectiveFrom`
/// (always a `Calendar.startOfDay`) until the next change supersedes it.
struct DailyGoalChange: Codable, Equatable {
    let effectiveFrom: Date
    let goalMinutes: Int
}

/// The daily goal, versioned by date so editing it never rewrites history.
///
/// A single stored number would re-judge every past day the moment it
/// changed — a streak built at 30 min/day would collapse when the goal moved
/// to 45, and finished graph dots would dim retroactively. This keeps the
/// *changes* instead, each stamped with the day it took effect. A day before
/// any recorded change (every day, for anyone who never edits the goal)
/// falls back to `defaultGoalMinutes`, so existing installs see no change.
struct DailyGoalSchedule: Equatable {
    static let defaultGoalMinutes = 30
    static let minimumGoalMinutes = 5
    static let maximumGoalMinutes = 180
    /// The increment the editor's minus/plus steps by, and the spacing its
    /// presets sit on.
    static let stepMinutes = 5

    /// Ascending by `effectiveFrom`. Every initialiser and mutation below
    /// maintains that, because `goalMinutes(on:)` resolves by taking the
    /// *last* match rather than searching.
    private(set) var changes: [DailyGoalChange]

    init(changes: [DailyGoalChange] = []) {
        self.changes = changes.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    func goalMinutes(on day: Date) -> Int {
        changes.last { $0.effectiveFrom <= day }?.goalMinutes ?? Self.defaultGoalMinutes
    }

    func goalSeconds(on day: Date) -> Double {
        Double(goalMinutes(on: day)) * 60
    }

    /// Applies from `today` onward only. Anything already stamped today (the
    /// user nudging the value repeatedly) or later is dropped first, so
    /// exactly one entry ever represents "now" and yesterday is never
    /// rewritten.
    mutating func setGoal(_ minutes: Int, from today: Date) {
        let clamped = min(max(minutes, Self.minimumGoalMinutes), Self.maximumGoalMinutes)
        changes.removeAll { $0.effectiveFrom >= today }
        changes.append(DailyGoalChange(effectiveFrom: today, goalMinutes: clamped))
    }
}
