import LucideSwift
import SwiftUI

/// The two-up "DAY STREAK | MINS READ" card beneath the day orb carousel.
/// Both numbers describe the carousel's currently selected day — the streak
/// itself is global (consecutive goal-met days ending at today), but tapping
/// the card always opens the selected day's own detail sheet, matching the
/// carousel/graph's shared "one selection" model documented on
/// `ContributionGraphView`.
struct StatsSummaryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let streak: Int
    let minutes: Int
    let goalMinutes: Int
    let action: () -> Void
    let onEditGoal: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                streakColumn
                Rectangle()
                    .fill(Color.appPrimaryText.opacity(0.10))
                    .frame(width: 1)
                    .padding(.vertical, 18)
                minutesColumn
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.appSecondaryBackground)
                    .shadow(color: Color.tabSelected.opacity(0.22), radius: 14, y: 5)
            }
        }
        .buttonStyle(.pressOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(streak) day streak, \(minutes) of \(goalMinutes) minutes read. Opens day detail."
        )
        // A `Button` in an overlay sits above the card's own button and is
        // hit-tested first, so a tap here edits the goal instead of opening
        // the day detail underneath it. Kept outside the card's label rather
        // than nested inside it, where the outer button would swallow it.
        .overlay(alignment: .topTrailing) { editGoalButton }
    }

    private var editGoalButton: some View {
        Button(action: onEditGoal) {
            LucideIcon(.pencil, size: 15, color: Color.appSecondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressOpacity)
        .accessibilityLabel("Edit daily goal")
        .accessibilityHint("Currently \(goalMinutes) minutes")
    }

    private var streakColumn: some View {
        VStack(spacing: 6) {
            // Passed as an `Int` interpolated on its own rather than a
            // preformatted string so `.numericText()` has two numbers
            // to roll between.
            Text("\(streak)")
                .font(.system(size: 40, weight: .medium, design: .serif))
                .foregroundStyle(Color.appPrimaryText)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: streak)
            Text("DAY STREAK")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var minutesColumn: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(minutes)")
                    .font(.system(size: 40, weight: .medium, design: .serif))
                    .foregroundStyle(Color.appPrimaryText)
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.28), value: minutes)

                Text("/\(goalMinutes)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appSecondaryText)
            }

            Text("MINS READ")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VStack(spacing: 16) {
        StatsSummaryCard(
            streak: 3, minutes: 12, goalMinutes: 30,
            action: {}, onEditGoal: {})
        StatsSummaryCard(
            streak: 0, minutes: 45, goalMinutes: 45,
            action: {}, onEditGoal: {})
    }
    .padding(20)
    .background(Color.appBackground)
}
