import LucideSwift
import SwiftUI

/// Pushed from Settings — a GitHub-style contribution graph of listening
/// activity, with a tappable day showing per-book detail. See
/// `ReadingStatsViewModel` for how the graph is derived (SwiftData has no
/// raw `GROUP BY`, so the day-bucketing happens here in Swift over rows
/// already filtered by the background actor).
struct ReadingStatsView: View {
    @StateObject private var viewModel: ReadingStatsViewModel

    init(readingStats: ReadingStatsStore) {
        _viewModel = StateObject(wrappedValue: ReadingStatsViewModel(store: readingStats))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                if viewModel.weeks.isEmpty {
                    emptyState
                } else {
                    ContributionGraphView(weeks: viewModel.weeks) { day in
                        Task { await viewModel.selectDay(day) }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .navigationTitle("Reading Stats")
        .task { await viewModel.loadIfNeeded() }
        .sheet(
            item: Binding(
                get: { viewModel.selectedDayDetail },
                set: { newValue in if newValue == nil { viewModel.clearSelectedDay() } })
        ) { detail in
            DayDetailView(detail: detail)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.chartColumn, style: .filled, size: 40, color: Color.appSecondaryText)
            Text("No reading activity yet").appText(.body)
            Text("Finish listening to a page and it'll show up here.")
                .appText(.label)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    NavigationStack {
        ReadingStatsView(readingStats: dependencies.readingStatsStore)
    }
    .preferredColorScheme(.dark)
}
