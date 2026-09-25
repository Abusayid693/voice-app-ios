import SwiftUI

/// GitHub-style contribution graph, restyled as a flat grid of dots —
/// chronological order (oldest first, most recent last), 18 per row,
/// wrapping downward same as reading text. No scroll view of its own: it's
/// meant to sit inside `ReadingStatsView`'s existing vertical `ScrollView`.
/// Deliberately built from per-cell `Button`s rather than drawn with
/// `Canvas`: each cell needs its own tap target to open that day's detail,
/// not just a color.
struct ContributionGraphView: View {
    let weeks: [[DayActivity?]]
    let onSelectDay: (Date) -> Void

    private let cellSize: CGFloat = 11.2
    private let cellSpacing: CGFloat = 10
    private let columnsPerRow = 18

    // Entrance animation tuning — kept small/fast on purpose so it reads as
    // a subtle settle-in, not a showy effect: ~9pt of travel, ~0.22s per
    // row, each row starting 0.022s after the previous one.
    private let entranceOffset: CGFloat = 9
    private let entranceDuration: CGFloat = 0.22
    private let entranceRowStagger: CGFloat = 0.022

    /// Drives the per-row enter transition below — starts `false` so every
    /// cell's initial frame is offset/transparent, flips once on appear so
    /// each row's `.animation(value:)` fires with its own staggered delay.
    @State private var hasAppeared = false

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
                repeating: GridItem(.flexible(), spacing: cellSpacing), count: columnsPerRow),
            spacing: cellSpacing
        ) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, activity in
                cell(for: activity, rowIndex: index / columnsPerRow)
            }
        }
        .accessibilityLabel("Reading activity by day")
        // Set once per appearance, not per data change — this is the
        // "opening the page" reveal, independent of whether `weeks` is
        // still the placeholder seed or real data by the time it fires.
        .onAppear { hasAppeared = true }
    }

    // Two independent animations on the same cell:
    // 1. Entrance — offset (-y -> resting) + opacity (0 -> 1), keyed off
    //    `hasAppeared` and staggered by `rowIndex`, so rows settle into
    //    place top to bottom the moment the page opens.
    // 2. Color — `weeks` (and so `days`) keeps the same day-for-day shape
    //    from the very first frame (see ReadingStatsViewModel's synchronous
    //    seed), so the only thing that changes once the real load resolves
    //    is each day's `intensityLevel`; animating that separately means a
    //    late-arriving color update still fades in smoothly even after the
    //    entrance has already finished, rather than snapping.
    private func cell(for activity: DayActivity, rowIndex: Int) -> some View {
        let rowDelay = Double(rowIndex) * entranceRowStagger

        return Button {
            onSelectDay(activity.day)
        } label: {
            Circle()
                .fill(Color.statsIntensity(level: activity.intensityLevel))
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
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : -entranceOffset)
        .animation(.easeOut(duration: entranceDuration).delay(rowDelay), value: hasAppeared)
        .animation(.easeOut(duration: 0.3).delay(rowDelay), value: activity.intensityLevel)
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
        .background(BookShelfPalette.background)
        .environment(\.colorScheme, .light)
}
