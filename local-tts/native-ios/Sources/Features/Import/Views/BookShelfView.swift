import LucideSwift
import SwiftUI

private enum BookShelfPalette {
    static let background = Color(hex: 0xF5F3ED)
    static let primaryText = Color(hex: 0x171715)
    static let secondaryText = Color(hex: 0x686761)
}

/// A focused, cover-led view of newly imported PDF projects. It deliberately
/// reads the existing LibraryViewModel index rather than maintaining another
/// book collection or copying reader-page content.
struct BookShelfView: View {
    @ObservedObject var library: LibraryViewModel
    let app: AppEnvironment

    @State private var openProject: SavedGeneration?

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
        Group {
            if books.isEmpty {
                emptyState
            } else {
                shelf
            }
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BookShelfPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Book Shelf")
                    .font(.custom("Didot-Bold", size: 28, relativeTo: .title2))
                    .foregroundStyle(BookShelfPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .navigationDestination(item: $openProject) { project in
            ChapterPlayerView(
                project: project, library: library,
                voiceCloneViewModel: app.voiceClone,
                chapterPlayer: app.chapterPlayer,
                generationStore: app.generationStore, viewModel: app.tts)
        }
        .tint(BookShelfPalette.primaryText)
        .preferredColorScheme(.light)
    }

    private var shelf: some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 16
            let coverSpacing: CGFloat = 24
            let coverWidth = min(max(geometry.size.width * 0.245, 84), 98)
            let coverSize = CGSize(width: coverWidth, height: coverWidth * 1.5)
            let shelfWidth = geometry.size.width - horizontalInset * 2

            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(Array(shelfRows.enumerated()), id: \.offset) { _, row in
                        BookShelfRow(
                            books: row,
                            coverSize: coverSize,
                            spacing: coverSpacing,
                            shelfWidth: shelfWidth
                        ) { book in
                            openProject = library.project(for: book.id)
                        }
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("PDF book shelves")
        }
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
            .contentMargins(.horizontal, 12, for: .scrollContent)

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
        BookShelfView(library: app.library, app: app)
    }
}
