import LucideSwift
import SwiftUI

enum BookShelfPalette {
    static let background = Color(hex: 0xF5F3ED)
    static let primaryText = Color(hex: 0x171715)
    static let secondaryText = Color(hex: 0x686761)
}

/// A focused, cover-led view of newly imported PDF projects. It deliberately
/// reads the existing LibraryViewModel index rather than maintaining another
/// book collection or copying reader-page content.
struct BookShelfView: View {
    @ObservedObject var library: LibraryViewModel
    let onOpenBook: (SavedGenerationSummary) -> Void

    private var books: [SavedGenerationSummary] {
        library.savedGenerations
            .filter { $0.source == .pdf }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var shelfRows: [[SavedGenerationSummary]] {
        var rows = stride(from: 0, to: books.count, by: 5).map { start in
            Array(books[start..<min(start + 5, books.count)])
        }
        while rows.count < 3 { rows.append([]) }
        return rows
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    shelfHeader

                    if books.isEmpty {
                        emptyState
                            .frame(minHeight: max(0, geometry.size.height - 100))
                    } else {
                        shelf(for: geometry.size.width)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("PDF book shelves")
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
    }

    private var shelfHeader: some View {
        VStack(spacing: 3) {
            Text("My Shelf")
                .font(.custom("Didot-Bold", size: 30, relativeTo: .title))
                .foregroundStyle(BookShelfPalette.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text("\(books.count) \(books.count == 1 ? "book" : "books")")
                .font(.caption.weight(.medium))
                .foregroundStyle(BookShelfPalette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func shelf(for availableWidth: CGFloat) -> some View {
        let horizontalInset: CGFloat = 8
        let coverSpacing: CGFloat = 12
        let coverWidth = min(max(availableWidth * 0.245, 84), 98)
        let coverSize = CGSize(width: coverWidth, height: coverWidth * 1.5)
        let shelfWidth = availableWidth - horizontalInset * 2

        return LazyVStack(spacing: 24) {
            ForEach(Array(shelfRows.enumerated()), id: \.offset) { index, row in
                BookShelfRow(
                    books: row,
                    coverSize: coverSize,
                    spacing: coverSpacing,
                    shelfWidth: shelfWidth,
                    leadingContentInset: index == 0 ? 30 : 16
                ) { book in
                    onOpenBook(book)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.book, style: .filled, size: 48, color: BookShelfPalette.secondaryText)
            Text("No PDF books yet")
                .font(AppTextStyle.body.font)
                .foregroundStyle(BookShelfPalette.primaryText)
            Text("Import a PDF from Home to add it to your shelf.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(BookShelfPalette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BookShelfRow: View {
    let books: [SavedGenerationSummary]
    let coverSize: CGSize
    let spacing: CGFloat
    let shelfWidth: CGFloat
    let leadingContentInset: CGFloat
    let onSelect: (SavedGenerationSummary) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(books) { book in
                        Button {
                            onSelect(book)
                        } label: {
                            SavedProjectCover(
                                coverURL: book.coverURL,
                                title: book.title,
                                size: coverSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.title), \(book.pageCountLabel)")
                        .accessibilityHint("Opens this book")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            // The glass shelf remains inset, while only the scroll viewport
            // extends to the screen edges so covers never clip at either end.
            .padding(.horizontal, -8)
            .contentMargins(.leading, leadingContentInset, for: .scrollContent)
            .contentMargins(.trailing, 16, for: .scrollContent)

            GlassBookShelf()
                .frame(
                    width: shelfWidth,
                    height: 18)
                .allowsHitTesting(false)
        }
        .frame(height: coverSize.height + 22)
    }
}

private struct GlassBookShelf: View {
    private let shape = UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: 10,
            bottomLeading: 2,
            bottomTrailing: 2,
            topTrailing: 10),
        style: .continuous)

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay {
            shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        BookShelfView(library: app.library, onOpenBook: { _ in })
    }
}
