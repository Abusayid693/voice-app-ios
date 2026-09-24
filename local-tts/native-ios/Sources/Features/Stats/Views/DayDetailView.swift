import LucideSwift
import SwiftUI

/// One day's detail, reached by tapping a cell in `ContributionGraphView` —
/// which books were read, pages completed, time listened, and voice used,
/// per book.
struct DayDetailView: View {
    let detail: DayDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryRow
                }
                .listRowBackground(Color.appSecondaryBackground)

                if detail.books.isEmpty {
                    Section {
                        Text("No activity this day.").appText(.labelDim)
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                } else {
                    Section("Books") {
                        ForEach(detail.books) { book in
                            bookRow(book)
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(detail.day.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var summaryRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.durationLabel(detail.totalListenedSeconds)).appText(.cardTitle)
                Text("listened").appText(.labelDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(detail.totalPagesCompleted)").appText(.cardTitle)
                Text(detail.totalPagesCompleted == 1 ? "page" : "pages").appText(.labelDim)
            }
        }
        .padding(.vertical, 4)
    }

    private func bookRow(_ book: DayDetailBookRow) -> some View {
        HStack(spacing: 12) {
            LucideIcon(.book, color: Color.appSecondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.bookTitle).appText(.rowTitle)
                Text(book.voiceNames.joined(separator: ", "))
                    .appText(.labelDim)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.durationLabel(book.listenedSeconds)).appText(.label)
                Text("\(book.pagesCompleted) \(book.pagesCompleted == 1 ? "page" : "pages")")
                    .appText(.labelDim)
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
