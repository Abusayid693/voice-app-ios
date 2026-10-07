import SwiftUI

/// GitHub-style contribution graph, restyled as a flat grid of dots —
/// chronological order (oldest first, most recent last), 18 per row,
/// wrapping downward same as reading text. No scroll view of its own: it's
/// meant to sit inside `ReadingStatsView`'s existing vertical `ScrollView`.
/// Deliberately built from per-cell `Button`s rather than drawn with
/// `Canvas`: each cell needs its own tap target to open that day's detail,
/// not just a color.
struct ContributionGraphView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let weeks: [[DayActivity?]]
    var isRevealed: Bool = true
    let onSelectDay: (Date) -> Void

    private let cellSize: CGFloat = 11.2
    // 70% of the original 10pt — same value drives both row and column
    // gaps (the grid's own `spacing:` and each GridItem's), so they stay
    // equal per the "row spacing matches column spacing" rule this was
    // originally tuned to.
    private let cellSpacing: CGFloat = 7
    static let columnsPerRow = 18

    /// `weeks` groups by weekday column for a 7-wide layout this view no
    /// longer uses, but it's already oldest-first within and across weeks —
    /// flatten it and drop the `nil` padding that alignment needed, and the
    /// chronological order falls out for free.
    private var days: [DayActivity] {
        weeks.flatMap { $0 }.compactMap { $0 }
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: cellSpacing), count: Self.columnsPerRow),
            spacing: cellSpacing
        ) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, activity in
                cell(for: activity, rowIndex: index / Self.columnsPerRow)
            }
        }
        .accessibilityLabel("Reading activity by day")
    }

    private func cell(for activity: DayActivity, rowIndex: Int) -> some View {
        Button {
            onSelectDay(activity.day)
        } label: {
            Circle()
                .fill(Color.statsIntensity(level: activity.intensityLevel, colorScheme: colorScheme))
                .frame(width: cellSize, height: cellSize)
                // Wider tap target than the dot itself, without changing
                // row height — a taller frame here was the row spacing
                // bug: it pushed rows apart further than columns, since
                // column spacing only ever comes from the grid's own
                // `spacing`, never from cell content.
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: activity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: activity.intensityLevel)
        .modifier(StatsEntranceReveal(
            isVisible: isRevealed, delay: StatsEntranceReveal.rowDelay(rowIndex)))
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
    let days: [DayActivity?] = (0..<64).map { offset in
        let day = calendar.date(byAdding: .day, value: -offset, to: today)!
        return DayActivity(
            day: day, listenedSeconds: Double([0, 120, 600, 1200, 2400].randomElement()!),
            pagesCompleted: Int.random(in: 0...4))
    }.reversed()
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    return ContributionGraphView(weeks: weeks) { _ in }
        .padding()
        .background(Color.appBackground)
        .environment(\.colorScheme, .dark)
}
