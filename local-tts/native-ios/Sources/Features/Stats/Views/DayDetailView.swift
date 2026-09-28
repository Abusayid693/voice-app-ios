import LucideSwift
import SwiftUI

/// One day's detail, reached by tapping a cell in `ContributionGraphView` —
/// which books were read, pages completed, time listened, and voice used,
/// per book. Light-themed with `BookShelfPalette` to match `ReadingStatsView`,
/// the light page this is presented from — unlike a pushed destination, a
/// `.sheet` needs its own explicit `.preferredColorScheme` rather than
/// inheriting one from the presenter's `.environment`.
struct DayDetailView: View {
    let detail: DayDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryRow
                }
                .listRowBackground(BookShelfPalette.background)

                if detail.books.isEmpty {
                    Section {
                        Text("No activity this day.")
                            .font(AppTextStyle.labelDim.font)
                            .foregroundStyle(BookShelfPalette.secondaryText)
                    }
                    .listRowBackground(BookShelfPalette.background)
                } else {
                    Section("Books") {
                        ForEach(detail.books) { book in
                            bookRow(book)
                        }
                    }
                    .listRowBackground(BookShelfPalette.background)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BookShelfPalette.background)
            .navigationTitle(detail.day.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .presentationDetents([.medium, .large])
    }

    private var summaryRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.durationLabel(detail.totalListenedSeconds))
                    .font(AppTextStyle.cardTitle.font)
                    .foregroundStyle(BookShelfPalette.primaryText)
                Text("listened")
                    .font(AppTextStyle.labelDim.font)
                    .foregroundStyle(BookShelfPalette.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(detail.totalPagesCompleted)")
                    .font(AppTextStyle.cardTitle.font)
                    .foregroundStyle(BookShelfPalette.primaryText)
                Text(detail.totalPagesCompleted == 1 ? "page" : "pages")
                    .font(AppTextStyle.labelDim.font)
                    .foregroundStyle(BookShelfPalette.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func bookRow(_ book: DayDetailBookRow) -> some View {
        HStack(spacing: 12) {
            LucideIcon(.book, color: BookShelfPalette.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.bookTitle)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(BookShelfPalette.primaryText)
                Text(book.voiceNames.joined(separator: ", "))
                    .font(AppTextStyle.labelDim.font)
                    .foregroundStyle(BookShelfPalette.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.durationLabel(book.listenedSeconds))
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(BookShelfPalette.primaryText)
                Text("\(book.pagesCompleted) \(book.pagesCompleted == 1 ? "page" : "pages")")
                    .font(AppTextStyle.labelDim.font)
                    .foregroundStyle(BookShelfPalette.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}

#Preview {
    Text("Host")
        .sheet(isPresented: .constant(true)) {
            DayDetailView(
                detail: DayDetail(
                    day: Date(), totalListenedSeconds: 1830, totalPagesCompleted: 3,
                    books: [
                        DayDetailBookRow(
                            projectID: UUID(), bookTitle: "The Great Gatsby", pagesCompleted: 2,
                            listenedSeconds: 1200, voiceNames: ["Bella"]),
                        DayDetailBookRow(
                            projectID: UUID(), bookTitle: "Moby Dick", pagesCompleted: 1,
                            listenedSeconds: 630, voiceNames: ["Alba"]),
                    ]))
        }
}
