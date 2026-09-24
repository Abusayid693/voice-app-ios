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
    let readingStats: ReadingStatsStore
    @Binding var isDetailPresented: Bool
    let onAddBooks: () -> Void
    let onOpenBook: (SavedGenerationSummary) -> Void

    @State private var selectedBook: SavedGenerationSummary?
    // Fraction of pages completed for the currently-open book's detail
    // modal — fetched once when it's presented (see presentDetail), not
    // observed reactively; a one-shot read matches this app's convention
    // for state a view merely reads on demand.
    @State private var selectedBookProgress: Double = 0
    @State private var selectedCoverFrame: CGRect?
    @State private var coverFrames: [UUID: CGRect] = [:]
    @State private var modalPhase: CGFloat = 0
    @State private var showsModalDetails = false
    @State private var isShelfCoverHidden = false
    @State private var isDismissingDetail = false
    // A short vertical hop (0 to -liftDistance) played just before the book
    // translates toward the center, and just after it translates back — so
    // the cover visibly lifts off/settles onto the shelf's glass lip instead
    // of appearing to pass straight through it.
    @State private var liftOffset: CGFloat = 0
    private let liftDistance: CGFloat = 15
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

                Button(action: onAddBooks) {
                    HStack(spacing: 6) {
                        // .secondary applies Color.secondaryButtonText via
                        // .foregroundStyle to the whole label, which Text
                        // picks up ambiently — LucideIcon needs it passed
                        // explicitly to match, same as every other call site.
                        LucideIcon(.plus, size: 16, color: Color.secondaryButtonText)
                        Text("Add books")
                    }
                }
                .buttonStyle(.secondary)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .padding(.bottom, 18)
                .accessibilityLabel("Add books")
                // Stays in place, dimmed behind the modal's backdrop, rather
                // than disappearing outright while the book detail is open.
                .allowsHitTesting(selectedBook == nil)
                .accessibilityHidden(selectedBook != nil)

                if let selectedBook {
                    BookShelfDetailModal(
                        book: selectedBook,
                        sourceFrame: selectedCoverFrame,
                        phase: modalPhase,
                        liftOffset: liftOffset,
                        showsCover: isShelfCoverHidden,
                        showsDetails: showsModalDetails,
                        progress: selectedBookProgress,
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
                    hiddenBookID: isShelfCoverHidden ? selectedBook?.id : nil,
                    // While the traveling overlay hasn't taken over yet, the
                    // real cover itself carries the lift — it stays in its
                    // native position beneath the glass shelf strip, so it
                    // visibly rises out from behind the glass instead of the
                    // overlay popping directly on top of it.
                    liftedBookID: isShelfCoverHidden ? nil : selectedBook?.id,
                    liftOffset: liftOffset,
                    liftAnimation: shelfLiftAnimation,
                    liftDistance: liftDistance
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

    // Whole open/close choreography tuned faster than the original pass,
    // then nudged back up 10% from that.
    private var translateAnimation: Animation {
        .spring(response: 0.23, dampingFraction: 0.94)
    }

    private var expandAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.92)
    }

    private var liftAnimation: Animation {
        .easeOut(duration: 0.20)
    }

    private var settleAnimation: Animation {
        .easeIn(duration: 0.20)
    }

    // Drives the real shelf cover's own offset (see BookShelfRow) — kept in
    // sync with liftAnimation/settleAnimation's duration above so the
    // sequenced steps that follow (translate, completeShelfReturn) don't
    // fire before the lift/settle has visually finished.
    private var shelfLiftAnimation: Animation {
        .easeInOut(duration: 0.20)
    }

    private func presentDetail(for book: SavedGenerationSummary) {
        guard selectedBook == nil, !isDismissingDetail else { return }
        selectedCoverFrame = coverFrames[book.id]
        modalPhase = reduceMotion ? 2 : 0
        showsModalDetails = reduceMotion
        selectedBookProgress = 0
        Task {
            let completed = await readingStats.completedPageIndices(forProject: book.id)
            guard selectedBook?.id == book.id else { return }
            selectedBookProgress = Double(completed.count) / Double(max(book.pageCount, 1))
        }
        var selectionTransaction = Transaction(animation: nil)
        selectionTransaction.disablesAnimations = true
        withTransaction(selectionTransaction) {
            // reduceMotion has no lift step, so the overlay takes over
            // immediately, same as before; otherwise the real shelf cover
            // keeps the visible artwork until the lift finishes.
            isShelfCoverHidden = reduceMotion
            selectedBook = book
            isDetailPresented = true
            liftOffset = 0
        }

        if reduceMotion {
            return
        }

        Task { @MainActor in
            // Leave one display frame for the destination card to measure its
            // intrinsic height while it is still exactly over the source book.
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard selectedBook?.id == book.id, !isDismissingDetail else { return }
            // Lift the real shelf cover clear of the glass lip first — it
            // stays in its native position beneath the glass strip, so it
            // visibly rises from behind the glass instead of the traveling
            // overlay popping directly on top of it.
            withAnimation(liftAnimation, completionCriteria: .logicallyComplete) {
                liftOffset = -liftDistance
            } completion: {
                guard selectedBook?.id == book.id, !isDismissingDetail else { return }
                // Hand off to the traveling overlay now that it's clear of
                // the shelf — both sit at the identical lifted position, so
                // the swap itself is invisible.
                var handoff = Transaction(animation: nil)
                handoff.disablesAnimations = true
                withTransaction(handoff) {
                    isShelfCoverHidden = true
                }
                withAnimation(translateAnimation, completionCriteria: .logicallyComplete) {
                    modalPhase = 1
                } completion: {
                    guard selectedBook?.id == book.id, !isDismissingDetail else { return }
                    withAnimation(expandAnimation, completionCriteria: .logicallyComplete) {
                        modalPhase = 2
                    } completion: {
                        guard selectedBook?.id == book.id, !isDismissingDetail else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            showsModalDetails = true
                        }
                    }
                }
            }
        }
    }

    private func dismissDetail(afterDismiss: (() -> Void)? = nil) {
        guard selectedBook != nil, !isDismissingDetail else { return }
        isDismissingDetail = true

        withAnimation(.easeOut(duration: 0.11)) {
            showsModalDetails = false
        }

        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: reduceMotion ? 77_000_000 : 108_000_000)

            if reduceMotion {
                withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
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
                    // Translate stops lifted just above the shelf slot (liftOffset
                    // is still -liftDistance here). Hand off back to the real
                    // shelf cover — still at the identical lifted position, so
                    // invisibly — then let it carry the settle down through the
                    // glass lip, rather than the overlay cutting through it.
                    var handoff = Transaction(animation: nil)
                    handoff.disablesAnimations = true
                    withTransaction(handoff) {
                        isShelfCoverHidden = false
                    }
                    withAnimation(settleAnimation, completionCriteria: .logicallyComplete) {
                        liftOffset = 0
                    } completion: {
                        completeShelfReturn(afterDismiss)
                    }
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
        liftOffset = 0
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
    let liftedBookID: UUID?
    let liftOffset: CGFloat
    let liftAnimation: Animation
    let liftDistance: CGFloat
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
                // Extra headroom above the covers equal to liftDistance —
                // ScrollView clips to its own bounds, and without this the
                // lifted cover's top edge crosses that clip line and gets
                // visibly cut off/jittery right at the peak of the lift.
                .padding(.top, 12 + liftDistance)
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
        // Bottom-aligned, so the extra liftDistance headroom is added above
        // the covers only — the shelf/glass strip's own bottom position is
        // unaffected.
        .frame(height: coverSize.height + 22 + liftDistance)
    }

    private func shelfCover(for book: SavedGenerationSummary) -> some View {
        SavedProjectCover(
            coverURL: book.coverURL,
            title: book.title,
            size: coverSize)
            .opacity(hiddenBookID == book.id ? 0 : 1)
            .animation(.linear(duration: 0.001), value: hiddenBookID)
            .offset(y: liftedBookID == book.id ? liftOffset : 0)
            // Nested inside the enclosing Button's own .transaction{nil}
            // override the same way the opacity animation above is — an
            // explicit .animation(_:value:) here is confirmed to win over
            // that override; a trailing one chained onto the Button itself
            // was not.
            .animation(liftAnimation, value: liftOffset)
    }
}

private struct BookShelfDetailModal: View {
    let book: SavedGenerationSummary
    let sourceFrame: CGRect?
    let phase: CGFloat
    // Extra vertical offset applied only at the shelf end of the translate
    // (see BookShelfView's lift/settle steps) — animates 0 -> -10 before the
    // cover starts moving, and -10 -> 0 after it arrives back, so it clears
    // the glass shelf's lip instead of appearing to cut through it.
    let liftOffset: CGFloat
    // False while the real shelf cover still owns the visible artwork
    // (during the pre-translate lift / post-translate settle) — the card and
    // traveling cover stay invisible until that handoff happens, so they
    // never sit exactly on top of the real cover across the glass boundary.
    let showsCover: Bool
    let showsDetails: Bool
    // Fraction of pages completed, 0...1 — fetched once by BookShelfView
    // when this modal is presented; see coverProgressBar.
    let progress: Double
    let onDismiss: () -> Void
    let onRead: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalCardSize: CGSize = .zero
    private let dismissDragThreshold: CGFloat = 80

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
                    .opacity(showsCover ? 1 : 0)
                    .transition(reduceMotion ? .opacity : .identity)
                    .gesture(dragToDismissGesture)
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
                    .opacity(showsCover ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Detection-only swipe-down-to-dismiss once the card is fully expanded —
    // the card doesn't follow the finger, it just triggers the normal
    // dismiss animation once the swipe clears the threshold on release.
    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard showsDetails else { return }
                let isDownwardSwipe = value.translation.height > 0
                    && abs(value.translation.height) > abs(value.translation.width)
                guard isDownwardSwipe else { return }
                if value.translation.height > dismissDragThreshold
                    || value.predictedEndTranslation.height > 220 {
                    onDismiss()
                }
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
        // liftOffset only has weight near the shelf end (translationProgress
        // near 0); once fully translated to the center it contributes
        // nothing, since progress = 1 discards the "from" term entirely.
        let liftedSourceMidY = resolvedSourceFrame.midY + (reduceMotion ? 0 : liftOffset)
        let cardCenter = CGPoint(
            x: interpolate(
                from: resolvedSourceFrame.midX,
                to: screenCenter.x,
                progress: translationProgress),
            y: interpolate(
                from: liftedSourceMidY,
                to: screenCenter.y,
                progress: translationProgress))
        // 52 top padding + the progress bar's own 3pt height + the 18pt
        // VStack spacing above it, then half the 252pt cover placeholder —
        // matches modalContent's real layout so the absolutely-positioned
        // cover art lands exactly over its reserved Color.clear spacer
        // instead of overlapping the progress bar above it.
        let finalCoverCenter = CGPoint(
            x: screenCenter.x,
            y: screenCenter.y - targetHeight / 2 + 52 + 3 + 18 + 126)
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
            coverProgressBar
                .opacity(showsDetails ? 1 : 0)

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

    // Real completed-pages fraction (see `progress`), matches the expanded
    // cover's own 168pt width.
    private var coverProgressBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .overlay {
                    Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                }
            Capsule()
                .fill(Color.black)
                .frame(width: 168 * CGFloat(min(max(progress, 0), 1)))
        }
        .frame(width: 168, height: 3)
        .accessibilityHidden(true)
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
            readingStats: app.readingStats,
            isDetailPresented: .constant(false),
            onAddBooks: {},
            onOpenBook: { _ in })
    }
}
