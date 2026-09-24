import SwiftUI

/// GitHub-style contribution graph — one column per week, one row per
/// weekday, horizontally scrollable so ~a year of weeks fits. Deliberately
/// built from per-cell `Button`s rather than drawn with `Canvas`: each cell
/// needs its own tap target to open that day's detail, not just a color.
struct ContributionGraphView: View {
    let weeks: [[DayActivity?]]
    let onSelectDay: (Date) -> Void

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3

    var body: some View {
        ScrollView(.horizontal) {
            LazyHGrid(
                rows: Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7),
                spacing: cellSpacing
            ) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    ForEach(Array(week.enumerated()), id: \.offset) { _, activity in
                        cell(for: activity)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        // Most recent week is the last column — land there, not at the
        // (potentially very old) start of the tracked range.
        .defaultScrollAnchor(.trailing)
        .accessibilityLabel("Reading activity by day")
    }

    @ViewBuilder
    private func cell(for activity: DayActivity?) -> some View {
        if let activity {
            Button {
                onSelectDay(activity.day)
            } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.statsIntensity(level: activity.intensityLevel))
                    .frame(width: cellSize, height: cellSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: activity))
        } else {
            // Padding cell — before the tracked range started, or after
            // today — no day exists here at all, not just "no activity".
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.clear)
                .frame(width: cellSize, height: cellSize)
                .accessibilityHidden(true)
        }
    }

    private func accessibilityLabel(for activity: DayActivity) -> String {
        let dateText = activity.day.formatted(date: .abbreviated, time: .omitted)
        guard activity.listenedSeconds > 0 else { return "\(dateText), no activity" }
        let minutes = Int(activity.listenedSeconds / 60)
        return
            "\(dateText), \(minutes) minute\(minutes == 1 ? "" : "s") listened, "
            + "\(activity.pagesCompleted) page\(activity.pagesCompleted == 1 ? "" : "s") completed"
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let days: [DayActivity?] = (0..<28).map { offset in
        let day = calendar.date(byAdding: .day, value: -offset, to: today)!
        return DayActivity(
            day: day, listenedSeconds: Double([0, 120, 600, 1200, 2400].randomElement()!),
            pagesCompleted: Int.random(in: 0...4))
    }.reversed()
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    return ContributionGraphView(weeks: weeks) { _ in }
        .padding()
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
