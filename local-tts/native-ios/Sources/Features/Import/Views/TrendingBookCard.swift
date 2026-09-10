import SwiftUI

/// One book's cover + title + author — shared between Import's 5-book
/// preview row and the full "See all" grid (which passes a larger
/// `coverSize`).
struct TrendingBookCard: View {
    let book: TrendingBook
    var coverSize: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: book.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    LinearGradient.stablePlaceholder(seed: "\(book.id)")
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(book.title)
                .font(.caption)
                .bold()
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
            Text(book.authorName)
                .font(.caption2)
                .foregroundStyle(Color.appSecondaryText)
                .lineLimit(1)
        }
        .frame(width: coverSize)
    }
}
