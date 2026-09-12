import LucideSwift
import SwiftUI

/// One book's cover + title + author — shared between Import's 5-book
/// preview row and the full "See all" grid (which passes a larger,
/// still-square `coverSize`).
struct TrendingBookCard: View {
    let book: TrendingBook
    // Square by default (matches "See all"'s real, aspect-varying Gutendex
    // covers, which have no single proportion to preserve). Import's
    // curated row instead passes an explicit coverHeight matching its
    // covers' real 2:3 aspect, so the cover shows uncropped.
    var coverSize: CGFloat = 110
    var coverHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .frame(width: coverSize, height: coverHeight ?? coverSize)
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

    // Curated books (ImportHomeView.curatedTrendingBooks) ship a bundled
    // cover and take priority; real Gutendex results only ever have a
    // remote coverURL, fetched via AsyncImage as before.
    @ViewBuilder
    private var cover: some View {
        if let localCoverAssetName = book.localCoverAssetName {
            Image(localCoverAssetName)
                .resizable()
                .scaledToFill()
        } else {
            AsyncImage(url: book.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    LinearGradient.stablePlaceholder(seed: "\(book.id)")
                        .overlay {
                            LucideIcon(.book, style: .filled, size: 28, color: .white.opacity(0.85))
                        }
                }
            }
        }
    }
}
