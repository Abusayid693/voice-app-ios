import LucideSwift
import SwiftUI

/// One OpenLibrary book's cover + title + author, for Import's
/// "New in romance" row.
struct OpenLibraryBookCard: View {
    let book: OpenLibraryBook
    var coverSize: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: book.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    LinearGradient.stablePlaceholder(seed: book.id)
                        .overlay {
                            LucideIcon(.book, style: .filled, size: 28, color: .white.opacity(0.85))
                        }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(book.title)
                .font(.appLabelStrong)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
            Text(book.authorName)
                .font(.appLabel)
                .foregroundStyle(Color.appSecondaryText)
                .lineLimit(1)
        }
        .frame(width: coverSize)
    }
}
