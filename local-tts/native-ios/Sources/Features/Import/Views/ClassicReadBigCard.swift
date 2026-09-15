import LucideSwift
import SwiftUI

/// One "Classic reads" hero card, matching the supplied mockup's large
/// single-focus layout: a tall cover on the left (with a circular preview
/// button overlaid on it) and title/author/duration/price stacked on the
/// right. Deliberately a bigger, different card language than every other
/// row on this screen (`ReadAnythingCard`/`OpenLibraryBookCard`'s small
/// grid cards) — see `ClassicReadsSection`'s doc comment for why.
struct ClassicReadBigCard: View {
    let item: ClassicReadItem
    let onPlayTapped: () -> Void

    static let cardHeight: CGFloat = 220
    private static let coverWidth: CGFloat = 165

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(item.coverAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: Self.coverWidth, height: Self.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    Button(action: onPlayTapped) {
                        LucideIcon(.volume2, size: 16, color: Color.appBackground)
                            .padding(10)
                            .background(Circle().fill(Color.appPrimaryText))
                    }
                    .padding(10)
                }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(2)
                    Text(item.authorName)
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(1)
                }

                // Same fixed literal on every card — see ClassicReadItem's
                // doc comment for why this isn't a stored field.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        LucideIcon(.clock, size: 14, color: Color.appTertiaryText)
                        Text("30 min")
                            .font(.caption)
                            .foregroundStyle(Color.appTertiaryText)
                    }
                    Text("Free Demo")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(Color.primaryButtonText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primaryButtonBackground))
                }
            }
            .frame(height: Self.cardHeight, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .frame(height: Self.cardHeight)
    }
}

#Preview {
    ClassicReadBigCard(
        item: ClassicReadItem(
            id: "preview", title: "Pride and Prejudice", authorName: "Jane Austen",
            coverAssetName: "BookCoverPrideAndPrejudice"),
        onPlayTapped: {}
    )
    .padding()
    .background(Color.appBackground)
}
