import LucideSwift
import SwiftUI

/// One OpenLibrary book's cover + title + author, for Import's
/// "New in romance" row.
struct OpenLibraryBookCard: View {
    let book: OpenLibraryBook
    var coverWidth: CGFloat = 117
    var coverHeight: CGFloat = 163

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
            .frame(width: coverWidth, height: coverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(book.title)
                .appText(.labelStrong)
                .lineLimit(1)
            Text(book.authorName)
                .appText(.label)
                .lineLimit(1)
        }
        .frame(width: coverWidth)
    }
}
