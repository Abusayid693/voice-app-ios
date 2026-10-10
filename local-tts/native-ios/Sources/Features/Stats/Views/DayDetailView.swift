import SwiftUI

/// One day's listening detail. Session data keeps raw voice codes for future
/// reporting, but this compact cover-and-metrics surface does not display them.
struct DayDetailView: View {
    let detail: DayDetail
    let coverURL: (UUID) -> URL?

    var body: some View {
        StandardBottomSheet(
            title: Self.dateFormatter.string(from: detail.day),
            detents: [.medium, .large]
        ) {
            summaryCard

            if detail.books.isEmpty {
                emptyState
            } else {
                booksSection
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            summaryRow(
                label: "Listened",
                value: Self.durationLabel(detail.totalListenedSeconds))
            summaryRow(
                label: "Pages Completed",
                value: "\(detail.totalPagesCompleted)")
            summaryRow(
                label: "Books Read",
                value: "\(detail.books.count)")
        }
        .padding(18)
        .background(
            Color.appSecondaryBackground,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(AppTextStyle.cardTitle.font)
                .foregroundStyle(Color.appSecondaryText)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    private var booksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Books")
                .font(AppTextStyle.sectionTitle.font)
                .foregroundStyle(Color.appPrimaryText)
                .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 12) {
                ForEach(detail.books) { book in
                    bookCard(book)
                }
            }
        }
    }

    private func bookCard(_ book: DayDetailBookRow) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SavedProjectCover(
                coverURL: coverURL(book.projectID),
                title: book.bookTitle,
                size: CGSize(width: 50, height: 74),
                cornerRadius: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(book.bookTitle)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.metricsLabel(for: book))
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.appTertiaryText)
            }
            .frame(minHeight: 74, alignment: .top)
        }
        .padding(14)
        .background(
            Color.appSecondaryBackground,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.appSecondaryText)
            Text("No reading activity")
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(Color.appPrimaryText)
            Text("Books you listen to on this day will appear here.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .background(
            Color.appSecondaryBackground,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        return formatter
    }()

    private static func metricsLabel(for book: DayDetailBookRow) -> String {
        let pages = "\(book.pagesCompleted) \(book.pagesCompleted == 1 ? "page" : "pages")"
        return "\(durationLabel(book.listenedSeconds)) · \(pages)"
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
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            DayDetailView(
                detail: DayDetail(
                    day: Date(),
                    totalListenedSeconds: 1_830,
                    totalPagesCompleted: 3,
                    books: [
                        DayDetailBookRow(
                            projectID: UUID(),
                            bookTitle: "The Great Gatsby",
                            pagesCompleted: 2,
                            listenedSeconds: 1_200,
                            voiceNames: ["af_heart", "bm_fable"]),
                        DayDetailBookRow(
                            projectID: UUID(),
                            bookTitle: "Moby Dick",
                            pagesCompleted: 1,
                            listenedSeconds: 630,
                            voiceNames: ["am_adam"]),
                    ]),
                coverURL: { _ in nil })
        }
}
