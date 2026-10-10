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
            // An empty day has nothing for the totals card to total and no
            // books to list — both are dropped rather than shown at zero,
            // in favor of one empty-state surface.
            if detail.books.isEmpty {
                noActivityState
            } else {
                summaryCard
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

    /// A day with nothing read, shown with the same app-preview marquee
    /// About opens on (`DesignSystem/ScreenshotMarquee`) at a size this
    /// sheet can hold, rather than a generic icon — it's showing what the
    /// app looks like in use, not that this one screen is empty. Full-bleed
    /// like About's own use of it: no card background, so the marquee's
    /// horizontal fade reaches the sheet's own true edge rather than stopping
    /// 24pt short of it — the negative padding below cancels exactly the
    /// inset `StandardBottomSheet` applies to every other piece of content.
    private var noActivityState: some View {
        VStack(spacing: 16) {
            ScreenshotMarquee(
                cardWidth: 76, cardHeight: 165, spacing: 10, cornerRadius: 13,
                verticalPadding: 26)
                .padding(.horizontal, -StandardBottomSheetMetrics.contentHorizontalPadding)

            VStack(spacing: 8) {
                Text("Read something to get stats")
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(Color.appPrimaryText)

                // Public-domain-era author, matching the sourcing the rest
                // of this feature already holds itself to (Gutenberg cover
                // art, Standard Ebooks' own mark) — nothing here needs a
                // usage clearance.
                (Text("“Reading is to the mind what exercise is to the body.”")
                    .italic()
                    + Text("\n— Joseph Addison")
                    .foregroundStyle(Color.appTertiaryText))
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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

#Preview("Empty") {
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            DayDetailView(
                detail: DayDetail(
                    day: Date(), totalListenedSeconds: 0, totalPagesCompleted: 0, books: []),
                coverURL: { _ in nil })
        }
}
