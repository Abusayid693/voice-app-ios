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
    @Binding var isDetailPresented: Bool
    let onAddBooks: () -> Void
    let onOpenBook: (SavedGenerationSummary) -> Void

    @State private var selectedBook: SavedGenerationSummary?
    @State private var selectedCoverFrame: CGRect?
    @State private var coverFrames: [UUID: CGRect] = [:]
    @State private var modalPhase: CGFloat = 0
    @State private var showsModalDetails = false
    @State private var isShelfCoverHidden = false
    @State private var isDismissingDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .scrollDisabled(selectedBook != nil)
                .allowsHitTesting(selectedBook == nil)
                .accessibilityHidden(selectedBook != nil)

                ShelfBottomBlur()
                    // The GeometryReader ends at the content safe area;
                    // extend and move the blur through the remaining inset
                    // so it reaches the physical bottom edge of the screen.
                    .frame(height: 96 + geometry.safeAreaInsets.bottom)
                    .frame(maxWidth: .infinity)
                    .offset(y: geometry.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)

                if selectedBook == nil {
                    Button(action: onAddBooks) {
                        Label("Add books", systemImage: "plus")
                    }
                    .buttonStyle(.secondary)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Add books")
                }

                if let selectedBook {
                    BookShelfDetailModal(
                        book: selectedBook,
                        sourceFrame: selectedCoverFrame,
                        phase: modalPhase,
                        showsDetails: showsModalDetails,
                        onDismiss: { dismissDetail() },
                        onRead: openSelectedBook)
                    .zIndex(1)
                }
            }
            .accessibilityLabel("PDF book shelves")
            .coordinateSpace(name: bookShelfModalCoordinateSpace)
            .onPreferenceChange(BookCoverFramePreferenceKey.self) { frames in
                coverFrames = frames
            }
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
        .onChange(of: isDetailPresented) { _, isPresented in
            if !isPresented, selectedBook != nil {
                modalPhase = 0
                showsModalDetails = false
                isShelfCoverHidden = false
                selectedBook = nil
                selectedCoverFrame = nil
                isDismissingDetail = false
            }
        }
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
                    leadingContentInset: index == 0 ? 30 : 16,
                    hiddenBookID: isShelfCoverHidden ? selectedBook?.id : nil
                ) { book in
                    presentDetail(for: book)
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

    private var translateAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.94)
    }

    private var expandAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.92)
    }

    private func presentDetail(for book: SavedGenerationSummary) {
        guard selectedBook == nil, !isDismissingDetail else { return }
        selectedCoverFrame = coverFrames[book.id]
        modalPhase = reduceMotion ? 2 : 0
        showsModalDetails = reduceMotion
        var selectionTransaction = Transaction(animation: nil)
        selectionTransaction.disablesAnimations = true
        withTransaction(selectionTransaction) {
            isShelfCoverHidden = true
            selectedBook = book
            isDetailPresented = true
        }

        if reduceMotion {
            return
        }

        Task { @MainActor in
            // Leave one display frame for the destination card to measure its
            // intrinsic height while it is still exactly over the source book.
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard selectedBook?.id == book.id, !isDismissingDetail else { return }
            withAnimation(translateAnimation, completionCriteria: .logicallyComplete) {
                modalPhase = 1
            } completion: {
                guard selectedBook?.id == book.id, !isDismissingDetail else { return }
                withAnimation(expandAnimation, completionCriteria: .logicallyComplete) {
                    modalPhase = 2
                } completion: {
                    guard selectedBook?.id == book.id, !isDismissingDetail else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        showsModalDetails = true
                    }
                }
            }
        }
    }

    private func dismissDetail(afterDismiss: (() -> Void)? = nil) {
        guard selectedBook != nil, !isDismissingDetail else { return }
        isDismissingDetail = true

        withAnimation(.easeOut(duration: 0.14)) {
            showsModalDetails = false
        }

        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: reduceMotion ? 100_000_000 : 140_000_000)

            if reduceMotion {
                withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                    modalPhase = 0
                } completion: {
                    completeShelfReturn(afterDismiss)
                }
                return
            }

            withAnimation(expandAnimation, completionCriteria: .logicallyComplete) {
                modalPhase = 1
            } completion: {
                withAnimation(translateAnimation, completionCriteria: .logicallyComplete) {
                    modalPhase = 0
                } completion: {
                    completeShelfReturn(afterDismiss)
                }
            }
        }
    }

    private func completeShelfReturn(_ completion: (() -> Void)?) {
        var handoffTransaction = Transaction(animation: nil)
        handoffTransaction.disablesAnimations = true
        withTransaction(handoffTransaction) {
            isShelfCoverHidden = false
        }

        Task { @MainActor in
            await Task.yield()
            withTransaction(handoffTransaction) {
                selectedBook = nil
                isDetailPresented = false
            }
            finishDismissal(completion)
        }
    }

    private func finishDismissal(_ completion: (() -> Void)?) {
        selectedCoverFrame = nil
        modalPhase = 0
        showsModalDetails = false
        isShelfCoverHidden = false
        isDismissingDetail = false
        completion?()
    }

    private func openSelectedBook() {
        guard let book = selectedBook else { return }
        dismissDetail {
            onOpenBook(book)
        }
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
    let hiddenBookID: UUID?
    let onSelect: (SavedGenerationSummary) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(books) { book in
                        Button {
                            onSelect(book)
                        } label: {
                            shelfCover(for: book)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.title), \(book.pageCountLabel)")
                        .accessibilityHint("Opens this book")
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BookCoverFramePreferenceKey.self,
                                    value: [
                                        book.id: proxy.frame(
                                            in: .named(bookShelfModalCoordinateSpace))
                                    ])
                            }
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
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

    private func shelfCover(for book: SavedGenerationSummary) -> some View {
        SavedProjectCover(
            coverURL: book.coverURL,
            title: book.title,
            size: coverSize)
            .opacity(hiddenBookID == book.id ? 0 : 1)
            .animation(.linear(duration: 0.001), value: hiddenBookID)
    }
}

private struct BookShelfDetailModal: View {
    let book: SavedGenerationSummary
    let sourceFrame: CGRect?
    let phase: CGFloat
    let showsDetails: Bool
    let onDismiss: () -> Void
    let onRead: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalCardSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let metrics = heroMetrics(in: geometry)

            ZStack {
                Color.black.opacity(0.28 * metrics.translationProgress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityLabel("Dismiss book details")
                    .transition(reduceMotion ? .opacity : .identity)

                detailCard(
                    targetWidth: metrics.targetWidth,
                    maximumHeight: max(0, min(geometry.size.height - 32, 650)))
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        modalCardSize = size
                    }
                    .frame(
                        width: metrics.cardSize.width,
                        height: metrics.cardSize.height)
                    .clipped()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: metrics.cornerRadius,
                            style: .continuous))
                    .position(metrics.cardCenter)
                    .shadow(
                        color: .black.opacity(0.22 * metrics.expansionProgress),
                        radius: 24 * metrics.expansionProgress,
                        y: 12 * metrics.expansionProgress)
                    .transition(reduceMotion ? .opacity : .identity)
                    .accessibilityElement(children: .contain)

                SavedProjectCover(
                    coverURL: book.coverURL,
                    title: book.title,
                    size: metrics.coverSize,
                    cornerRadius: metrics.coverCornerRadius)
                    .position(metrics.coverCenter)
                    .shadow(
                        color: .black.opacity(0.16 * metrics.expansionProgress),
                        radius: 12 * metrics.expansionProgress,
                        y: 6 * metrics.expansionProgress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailCard(
        targetWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> some View {
        ViewThatFits(in: .vertical) {
            modalContent

            ScrollView(.vertical, showsIndicators: false) {
                modalContent
            }
            .frame(height: maximumHeight)
        }
        .frame(width: targetWidth)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(BookShelfPalette.background)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                LucideIcon(.x, size: 20, color: BookShelfPalette.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .opacity(showsDetails ? 1 : 0)
            .allowsHitTesting(showsDetails)
            .accessibilityHidden(!showsDetails)
            .accessibilityLabel("Close book details")
        }
    }

    private func heroMetrics(in geometry: GeometryProxy) -> BookHeroMetrics {
        let targetWidth = max(1, min(geometry.size.width - 32, 380))
        let resolvedSourceFrame = sourceFrame ?? CGRect(
            x: geometry.size.width / 2 - 45,
            y: geometry.size.height / 2 - 67.5,
            width: 90,
            height: 135)
        let targetHeight = modalCardSize.height > 0
            ? modalCardSize.height
            : targetWidth * 1.5
        let translationProgress = reduceMotion ? 1 : min(max(phase, 0), 1)
        let expansionProgress = reduceMotion ? 1 : min(max(phase - 1, 0), 1)
        let screenCenter = CGPoint(
            x: geometry.size.width / 2,
            y: geometry.size.height / 2)
        let cardCenter = CGPoint(
            x: interpolate(
                from: resolvedSourceFrame.midX,
                to: screenCenter.x,
                progress: translationProgress),
            y: interpolate(
                from: resolvedSourceFrame.midY,
                to: screenCenter.y,
                progress: translationProgress))
        let finalCoverCenter = CGPoint(
            x: screenCenter.x,
            y: screenCenter.y - targetHeight / 2 + 52 + 126)
        let translatedCoverCenter = cardCenter
        let coverCenter = CGPoint(
            x: interpolate(
                from: translatedCoverCenter.x,
                to: finalCoverCenter.x,
                progress: expansionProgress),
            y: interpolate(
                from: translatedCoverCenter.y,
                to: finalCoverCenter.y,
                progress: expansionProgress))

        return BookHeroMetrics(
            targetWidth: targetWidth,
            translationProgress: translationProgress,
            expansionProgress: expansionProgress,
            cardSize: CGSize(
                width: interpolate(
                    from: resolvedSourceFrame.width,
                    to: targetWidth,
                    progress: expansionProgress),
                height: interpolate(
                    from: resolvedSourceFrame.height,
                    to: targetHeight,
                    progress: expansionProgress)),
            cardCenter: cardCenter,
            cornerRadius: interpolate(from: 3, to: 28, progress: expansionProgress),
            coverSize: CGSize(
                width: interpolate(
                    from: resolvedSourceFrame.width,
                    to: 168,
                    progress: expansionProgress),
                height: interpolate(
                    from: resolvedSourceFrame.height,
                    to: 252,
                    progress: expansionProgress)),
            coverCenter: coverCenter,
            coverCornerRadius: interpolate(from: 3, to: 8, progress: expansionProgress))
    }

    private var modalContent: some View {
        VStack(spacing: 18) {
            Color.clear
                .frame(width: 168, height: 252)

            VStack(spacing: 18) {
                Text(book.title)
                    .font(.custom("Didot-Bold", size: 28, relativeTo: .title))
                    .foregroundStyle(BookShelfPalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                VStack(spacing: 12) {
                    detailRow("Date added", value: book.createdAt.formatted(date: .abbreviated, time: .omitted))
                    detailRow("Pages", value: book.pageCountLabel)
                    detailRow("Estimated time", value: estimatedReadingTime)
                }
                .padding(.vertical, 2)

                Button(action: onRead) {
                    Text("Read this")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(BookShelfPalette.primaryText, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Closes book details and opens the reader")
            }
            .opacity(showsDetails ? 1 : 0)
            .allowsHitTesting(showsDetails)
            .accessibilityHidden(!showsDetails)
        }
        .padding(.horizontal, 28)
        .padding(.top, 52)
        .padding(.bottom, 20)
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(BookShelfPalette.secondaryText)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BookShelfPalette.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private var estimatedReadingTime: String {
        let minutes = max(book.pageCount, 0) * 5
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours == 0 { return "~\(minutes) min" }
        if remainder == 0 { return "~\(hours) hr" }
        return "~\(hours) hr \(remainder) min"
    }
}

private let bookShelfModalCoordinateSpace = "book-shelf-modal"

private struct BookCoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct BookHeroMetrics {
    let targetWidth: CGFloat
    let translationProgress: CGFloat
    let expansionProgress: CGFloat
    let cardSize: CGSize
    let cardCenter: CGPoint
    let cornerRadius: CGFloat
    let coverSize: CGSize
    let coverCenter: CGPoint
    let coverCornerRadius: CGFloat
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
        BookShelfView(
            library: app.library,
            isDetailPresented: .constant(false),
            onAddBooks: {},
            onOpenBook: { _ in })
    }
}
