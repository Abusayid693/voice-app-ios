import LucideSwift
import SwiftUI

enum BookShelfPalette {
    static let background = Color.whitePaper
    static let primaryText = Color(hex: 0x171715)
    static let secondaryText = Color(hex: 0x686761)
}

/// A focused, cover-led view of newly imported PDF projects. It deliberately
/// reads the existing LibraryViewModel index rather than maintaining another
/// book collection or copying reader-page content.
struct BookShelfView: View {
    @ObservedObject var library: LibraryViewModel
    let onAddBooks: () -> Void
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
            ZStack(alignment: .bottom) {
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
                    // Keep only a small trailing inset so shelves can pass
                    // underneath the progressive blur and Add Books action.
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                ShelfBottomBlur()
                    // The GeometryReader ends at the content safe area;
                    // extend and move the blur through the remaining inset
                    // so it reaches the physical bottom edge of the screen.
                    .frame(height: 96 + geometry.safeAreaInsets.bottom)
                    .frame(maxWidth: .infinity)
                    .offset(y: geometry.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)

                Button(action: onAddBooks) {
                    Label("Add books", systemImage: "plus")
                }
                .buttonStyle(.secondary)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .padding(.bottom, 18)
                .accessibilityLabel("Add books")
            }
            .accessibilityLabel("PDF book shelves")
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
    }

    private var shelfHeader: some View {
        ZStack {
            ShelfHeaderBackdrop(books: Array(books.prefix(3)))
                // The decorative canvas is intentionally larger than the
                // header's layout footprint, so its soft colour can extend
                // behind the shelf without moving the title or shelf rows.
                .frame(height: 160)
                .clipped()

            VStack(spacing: 3) {
                Text("My Shelf")
                    .font(.custom("Didot-Bold", size: 30, relativeTo: .title))
                    .foregroundStyle(BookShelfPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)

                Text("\(books.count) \(books.count == 1 ? "book" : "books")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BookShelfPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .padding(.bottom, 4)
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

/// Mirrors the reader's navigation chrome at the bottom edge without adding
/// a solid bar: the material begins clear and gradually gains blur near the
/// safe area.
private struct ShelfBottomBlur: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55), .black],
                    startPoint: .top,
                    endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }
}

/// A restrained, decorative echo of the newest covers. It is deliberately
/// blurred enough to read as colour and depth behind the Shelf title rather
/// than as another actionable set of books.
private struct ShelfHeaderBackdrop: View {
    let books: [SavedGenerationSummary]

    // Fits inside the compact decorative canvas even after the outer covers'
    // rotation, so the blurred artwork does not clip at either edge.
    private let coverSize = CGSize(width: 64, height: 96)
    private let positions: [CGFloat] = [0.30, 0.5, 0.70]
    private let angles: [Double] = [-11, 0, 11]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    SavedProjectCover(
                        coverURL: book.coverURL,
                        title: book.title,
                        size: coverSize,
                        cornerRadius: 8)
                    .saturation(1.25)
                    .blur(radius: 8)
                    .opacity(0.22)
                    .rotationEffect(.degrees(angles[index]))
                    .position(
                        x: geometry.size.width * positions[index],
                        y: geometry.size.height * 0.5)
                    .accessibilityHidden(true)
                }
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        BookShelfView(library: app.library, onAddBooks: {}, onOpenBook: { _ in })
    }
}
