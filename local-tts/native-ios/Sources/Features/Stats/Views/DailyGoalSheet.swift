import SwiftUI

/// Editor for the daily reading goal, opened from `StatsSummaryCard`'s
/// pencil. Hosted by `StandardBottomSheet`, the same flat opaque chrome
/// Storage and Tools' catalog explainer use, for visual consistency across
/// this app's utility sheets.
///
/// An earlier version of this sheet used `InteractiveGlassBottomSheet`'s
/// `.clearGlass` style on purpose, so the carousel/card/header glow stayed
/// visible and re-derived live behind it as the goal moved — the clearest
/// possible preview of what a new value meant. Matching `StandardBottomSheet`
/// here gives that up deliberately: every control still applies immediately
/// rather than behind a Save button, but the live preview-through-glass
/// effect is gone along with the transparency that made it possible.
///
/// Changing the goal only ever affects today and later — see
/// `DailyGoalSchedule` for how past days keep the goal they were originally
/// judged against.
struct DailyGoalSheet: View {
    let goalMinutes: Int
    let onSelect: (Int) -> Void

    private let presets = [10, 15, 20, 30, 45, 60]

    private var canDecrease: Bool {
        goalMinutes > DailyGoalSchedule.minimumGoalMinutes
    }

    private var canIncrease: Bool {
        goalMinutes < DailyGoalSchedule.maximumGoalMinutes
    }

    var body: some View {
        StandardBottomSheet(title: "Daily goal", detents: [.height(330)]) {
            stepper
            presetRow

            Text("Applies from today onward. Days you've already finished keep the goal they were set at.")
                .appText(.label)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepper: some View {
        HStack(spacing: 26) {
            stepButton(systemName: "minus", enabled: canDecrease) {
                onSelect(goalMinutes - DailyGoalSchedule.stepMinutes)
            }
            .accessibilityLabel("Decrease goal")

            VStack(spacing: 2) {
                Text("\(goalMinutes)")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.appPrimaryText)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.22), value: goalMinutes)
                Text(goalMinutes == 1 ? "minute" : "minutes")
                    .appText(.meta)
            }
            .frame(minWidth: 110)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(goalMinutes) minutes")

            stepButton(systemName: "plus", enabled: canIncrease) {
                onSelect(goalMinutes + DailyGoalSchedule.stepMinutes)
            }
            .accessibilityLabel("Increase goal")
        }
    }

    private func stepButton(
        systemName: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Color.appPrimaryText : Color.appTertiaryText)
                .frame(width: 44, height: 44)
                .background(Color.appPrimaryText.opacity(0.10), in: Circle())
        }
        .buttonStyle(.pressOpacity)
        .disabled(!enabled)
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { preset in
                let isSelected = preset == goalMinutes
                Button {
                    onSelect(preset)
                } label: {
                    Text("\(preset)")
                        // Not `.appText(.labelStrong)`: that bakes in
                        // `.appPrimaryText` as a `ModifiedContent` layer
                        // closer to this `Text` than anything chained after
                        // it, so a later `.foregroundStyle` here never
                        // actually wins — the color has to be set once,
                        // matching the selection state, or the selected
                        // pill renders white text on its own white fill.
                        .font(AppTextStyle.labelStrong.font)
                        .foregroundStyle(
                            isSelected ? Color.appBackground : Color.appPrimaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            isSelected
                                ? Color.appPrimaryText
                                : Color.appPrimaryText.opacity(0.10),
                            in: Capsule())
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel("\(preset) minute goal")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

#Preview {
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            DailyGoalSheet(goalMinutes: 30, onSelect: { _ in })
        }
}
