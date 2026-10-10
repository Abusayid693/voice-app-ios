import SwiftUI

/// The retained Stats tab root: a day orb carousel (one glowing sphere per
/// day, brightness toward the 30-min daily goal), the selected day's date
/// and minutes, a streak/time-read summary card that opens that day's
/// detail, and a 3-month contribution graph below a section title.
///
/// The whole top half of the page describes **one selected day** —
/// `ReadingStatsViewModel.selectedDay` — which the carousel, caption, and
/// summary card all read from and the carousel/graph can both move. See
/// `ReadingStatsViewModel` for how that day's numbers and the streak are
/// derived (SwiftData has no raw `GROUP BY`, so the day-bucketing happens
/// here in Swift over rows already filtered by the background actor).
struct ReadingStatsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: ReadingStatsViewModel
    @State private var contentRevealed = false
    @State private var isGoalSheetPresented = false
    let refreshToken: Int
    let isActive: Bool

    init(readingStats: ReadingStatsStore, refreshToken: Int = 0, isActive: Bool = true) {
        _viewModel = StateObject(wrappedValue: ReadingStatsViewModel(store: readingStats))
        self.refreshToken = refreshToken
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TexturedDarkBackground(variant: .topGlow(intensity: selectedDayProgress))
                    .ignoresSafeArea()
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.35), value: selectedDayProgress)

                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                        StatsSignatureTitle(isRevealed: contentRevealed)
                            .frame(maxWidth: .infinity, alignment: .center)

                        VStack(spacing: 18) {
                            DayOrbCarousel(
                                days: viewModel.days, selectedDay: $viewModel.selectedDay,
                                isRevealed: contentRevealed)
                                // Cancels the VStack's own 20pt horizontal
                                // inset below, so the carousel's scroll
                                // viewport reaches the physical screen edges
                                // — every other section keeps the margin,
                                // only this one bleeds. `DayOrbCarousel`
                                // insets its own content by half an item
                                // width via `contentMargins`, which is what
                                // actually keeps the first/last orb centered
                                // rather than flush against the edge.
                                .padding(.horizontal, -20)

                            selectedDayCaption
                                .modifier(StatsEntranceReveal(isVisible: contentRevealed, delay: 0.16))
                        }

                        StatsSummaryCard(
                            streak: viewModel.currentStreak,
                            minutes: Int((viewModel.selectedDayActivity?.listenedSeconds ?? 0) / 60),
                            goalMinutes: viewModel.currentGoalMinutes,
                            action: { Task { await viewModel.selectDay(viewModel.selectedDay) } },
                            onEditGoal: { isGoalSheetPresented = true })
                        .modifier(StatsEntranceReveal(isVisible: contentRevealed, delay: 0.22))

                        monthsGraphSection
                            .modifier(StatsEntranceReveal(isVisible: contentRevealed, delay: 0.28))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 50)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task(id: refreshToken) { await viewModel.reload() }
        .task(id: EntranceTrigger(isActive: isActive, refreshToken: refreshToken, reduceMotion: reduceMotion)) {
            resetEntrance()
            guard isActive else { return }
            if !reduceMotion {
                // Commit the hidden starting pose before animating the retained tab.
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            contentRevealed = true
        }
        .onDisappear { resetEntrance() }
        .sheet(
            item: Binding(
                get: { viewModel.selectedDayDetail },
                set: { newValue in if newValue == nil { viewModel.clearSelectedDay() } })
        ) { detail in
            DayDetailView(detail: detail)
        }
        .sheet(isPresented: $isGoalSheetPresented) {
            DailyGoalSheet(
                goalMinutes: viewModel.currentGoalMinutes,
                onSelect: { viewModel.setGoal($0) })
        }
    }

    private struct EntranceTrigger: Equatable {
        let isActive: Bool
        let refreshToken: Int
        let reduceMotion: Bool
    }

    /// Drives `.topGlow`'s own intensity — the header's orange brightens and
    /// dims with the exact same number the centred orb's fill does, so the
    /// background reads as the same measurement rather than a second,
    /// unrelated one.
    private var selectedDayProgress: Double {
        viewModel.selectedDayActivity?.goalProgress ?? 0
    }

    private func resetEntrance() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { contentRevealed = false }
    }

    private static let selectedDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        return formatter
    }()

    private var selectedDayCaption: some View {
        let minutes = Int((viewModel.selectedDayActivity?.listenedSeconds ?? 0) / 60)
        return VStack(spacing: 2) {
            Text(Self.selectedDayFormatter.string(from: viewModel.selectedDay))
                .appText(.sectionTitle)
                // Whole-string crossfade — the date changes to an unrelated
                // string, so there's nothing for `.numericText()` to roll
                // between the way there is for the minute count below.
                .contentTransition(.opacity)
            Text(minutes == 1 ? "1 min" : "\(minutes) min")
                .appText(.label)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: viewModel.selectedDay)
    }

    private var monthsGraphSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Last 3 months")
                .font(.custom("EBGaramond-Regular", size: 20, relativeTo: .title3))
                .foregroundStyle(Color.appPrimaryText)

            if viewModel.days.isEmpty {
                emptyState
            } else {
                ContributionGraphView(
                    days: viewModel.days, selectedDay: viewModel.selectedDay,
                    isRevealed: contentRevealed, rowDelayBase: 0.34
                ) { day in
                    viewModel.selectedDay = day
                }
            }
        }
        .padding(20)
        .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 24))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No reading activity yet")
                .appText(.body)
            Text("Finish listening to a page and it'll show up here.")
                .appText(.label)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Replaced the earlier `SignatureText` hand-writing ink reveal — plain
/// text under `StatsEntranceReveal`, the same single fade-and-rise every
/// other section of this page (the carousel, the caption, the summary
/// card, the graph) already enters with, rather than a bespoke effect of
/// its own.
private struct StatsSignatureTitle: View {
    let isRevealed: Bool

    private static let text = "Reading Stats"

    var body: some View {
        // EB Garamond Regular (the upright counterpart to the already-
        // bundled EBGaramond-Italic — same family/weight axis, from the
        // same Google Fonts source) at its own default weight — matching
        // the "Library"/"Tools" page titles' own treatment rather than the
        // system serif this replaced.
        Text(Self.text)
            .font(.custom("EBGaramond-Regular", size: 38, relativeTo: .title))
            .foregroundStyle(Color.appPrimaryText)
            .accessibilityAddTraits(.isHeader)
            .modifier(StatsEntranceReveal(isVisible: isRevealed, delay: 0))
    }
}

/// Opacity and translation leave the final layout in place throughout the reveal.
struct StatsEntranceReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let delay: Double

    private let animationSpeedMultiplier = 1.2

    static func rowDelay(_ row: Int, base: Double = 0.20) -> Double { base + Double(row) * 0.022 }

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 10)
            .animation(
                isVisible && !reduceMotion
                    ? .easeOut(duration: 0.38 / animationSpeedMultiplier)
                        .delay(delay / animationSpeedMultiplier) : nil,
                value: isVisible)
            .allowsHitTesting(reduceMotion || isVisible)
            .accessibilityHidden(!reduceMotion && !isVisible)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ReadingStatsView(readingStats: dependencies.readingStatsStore)
}
