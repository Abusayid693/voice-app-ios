import LucideSwift
import SwiftUI

/// Presented from Book Shelf's weekly activity dots (`ImportHomeView.
/// recentActivityDots`) — a GitHub-style contribution graph of listening
/// activity, with a tappable day showing per-book detail, plus today's own
/// date header and a half-circle goal gauge. Uses the app's dark palette.
/// See `ReadingStatsViewModel` for how the graph is derived (SwiftData has
/// no raw `GROUP BY`, so the day-bucketing happens here in Swift over rows
/// already filtered by the background actor).
struct ReadingStatsView: View {
    @StateObject private var viewModel: ReadingStatsViewModel

    /// Today's listening goal, in minutes — a fixed target for now; there's
    /// no per-user goal setting yet.
    private let dailyGoalMinutes = 30

    init(readingStats: ReadingStatsStore) {
        _viewModel = StateObject(wrappedValue: ReadingStatsViewModel(store: readingStats))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TexturedDarkBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                        currentDayHeader

                        if viewModel.weeks.isEmpty {
                            emptyState
                        } else {
                            ContributionGraphView(weeks: viewModel.weeks) { day in
                                Task { await viewModel.selectDay(day) }
                            }
                        }

                        dailyGoalGauge
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Reading Stats")
                        .font(.custom("EBGaramond-Italic", size: 36, relativeTo: .title))
                        .fontWeight(.medium)
                        .foregroundStyle(Color.appPrimaryText)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await viewModel.loadIfNeeded() }
        .sheet(
            item: Binding(
                get: { viewModel.selectedDayDetail },
                set: { newValue in if newValue == nil { viewModel.clearSelectedDay() } })
        ) { detail in
            DayDetailView(detail: detail)
        }
    }

    private static let currentDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM, yyyy"
        return formatter
    }()

    private var currentDayHeader: some View {
        Text(Self.currentDayFormatter.string(from: Date()))
            .font(AppTextStyle.sectionTitle.font)
            .foregroundStyle(Color.appPrimaryText)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.chartColumn, style: .filled, size: 40, color: Color.appSecondaryText)
            Text("No reading activity yet")
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
            Text("Finish listening to a page and it'll show up here.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var dailyGoalGauge: some View {
        let minutes = Int(viewModel.todayListenedSeconds / 60)
        let progress = dailyGoalMinutes > 0 ? Double(minutes) / Double(dailyGoalMinutes) : 0

        return VStack(spacing: 10) {
            HalfCircleGaugeView(progress: progress) {
                VStack(spacing: 2) {
                    Text("\(minutes)")
                        .font(AppTextStyle.title.font)
                        .foregroundStyle(Color.appPrimaryText)
                    Text(minutes == 1 ? "min read today" : "mins read today")
                        .font(AppTextStyle.labelDim.font)
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            Text("of \(dailyGoalMinutes) min goal")
                .font(AppTextStyle.meta.font)
                .foregroundStyle(Color.appSecondaryText)
        }
        .padding(.top, 8)
    }
}

/// A gauge-style progress arc over the top half of a circle (flat edge at
/// the bottom, like a speedometer) — `content` sits inside the flat lower
/// half it leaves empty. Generic over its center content rather than a
/// fixed label, in case a future stat reuses the same shape.
private struct HalfCircleGaugeView<Content: View>: View {
    /// Not clamped internally — callers decide whether going over 1 should
    /// still read as "full" (clamped here) or, if ever wanted, overflow
    /// styling; today it's always clamped at the call site's math too since
    /// hitting/exceeding the goal both just mean "full arc".
    let progress: Double
    let content: () -> Content

    /// Sweeps from 0 up to `progress` once, animated, rather than the arc
    /// snapping straight to its resting value — separate from `progress`
    /// itself so a *later* real change (today's minutes ticking up while
    /// this page stays open) can re-animate too, via `.onChange` below,
    /// without re-triggering `.onAppear`'s one-time entrance sweep.
    @State private var animatedProgress: Double = 0

    private let diameter: CGFloat = 200
    private let lineWidth: CGFloat = 16

    init(progress: Double, @ViewBuilder content: @escaping () -> Content) {
        self.progress = progress
        self.content = content
    }

    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack(alignment: .top) {
            arc(from: 0.5, to: 1, color: Color.appPrimaryText.opacity(0.12))
            // Always present (not gated on progress > 0) so it has
            // something to animate *from* — conditionally inserting the
            // view at a later progress would just pop in at full length
            // instead of sweeping.
            arc(
                from: 0.5, to: 0.5 + 0.5 * animatedProgress,
                color: Color.appPrimaryText)
        }
        // A round `lineCap` stroke extends past the mathematical circle in
        // every direction it has an endpoint or apex — not just the top —
        // so clearance is needed on all 4 sides, not only a tight height
        // crop, or the cap at 12 o'clock (and the two arc ends at 9/3
        // o'clock) render visibly flattened where they'd cross frame 0.
        .padding(lineWidth / 2)
        // Only the height needs constraining — the padded width already
        // matches what should stay visible, nothing to crop horizontally.
        .frame(height: diameter / 2 + lineWidth, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            content()
                .padding(.bottom, 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                animatedProgress = clampedProgress
            }
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeOut(duration: 0.6)) {
                animatedProgress = clampedProgress
            }
        }
    }

    // Circle().trim(from: 0.5, to: 1) sweeps 9 o'clock -> 12 o'clock -> 3
    // o'clock, i.e. exactly the top half — no rotation needed, and that
    // upper half (plus the `lineWidth/2` clearance from the padding above)
    // is what the outer `.clipped()` frame keeps.
    private func arc(from: CGFloat, to: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ReadingStatsView(readingStats: dependencies.readingStatsStore)
}
