import LucideSwift
import SwiftUI

enum BookShelfPalette {
    static let background = Color.whitePaper
    static let primaryText = Color(hex: 0x171715)
    static let secondaryText = Color(hex: 0x686761)
}

/// Progressive blur under Home's floating header controls: one
/// `.ultraThinMaterial` band whose gradient mask starts fading immediately,
/// so the softening is strongest behind the icons and gone well before the
/// shelf title. Deliberately a single light layer — stacked materials read
/// as an opaque frosted panel rather than a gentle edge. Shelf content
/// scrolls underneath it.
struct ShelfTopBlur: View {
    /// Roughly the status bar plus `BookShelfView.headerControlsInset`.
    var height: CGFloat = 104

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(
                    colors: [.black, .black.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom))
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A focused, cover-led view of newly imported PDF projects. It deliberately
/// reads the existing LibraryViewModel index rather than maintaining another
/// book collection or copying reader-page content.
struct BookShelfView: View {
    @ObservedObject var library: LibraryViewModel
    // Passed through to a narrow child observer so per-page import progress
    // does not invalidate the full shelf and its cover geometry.
    let pdfImports: PDFImportManager
    let readingStats: ReadingStatsStore
    @Binding var isDetailPresented: Bool
    let onOpenBook: (SavedGenerationSummary) -> Void

    @State private var selectedBook: SavedGenerationSummary?
    // Fraction of pages completed for the currently-open book's detail
    // modal — fetched once when it's presented (see presentDetail), not
    // observed reactively; a one-shot read matches this app's convention
    // for state a view merely reads on demand.
    @State private var selectedBookProgress: Double = 0
    @State private var selectedCoverFrame: CGRect?
    @State private var coverFrames: [UUID: CGRect] = [:]
    /// Where each book's cover *face* sits — the modal hero's source. Differs
    /// from `coverFrames` for a spine-out book; see BookHeroFramePreferenceKey.
    @State private var heroFrames: [UUID: CGRect] = [:]
    /// True while the detail modal owns `selectedBook`: a spine-out book is
    /// turned face-out for the lift, and turned back on the way down.
    @State private var detailShowsCoverFace = false
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

    // MARK: - Long-press arrange mode
    //
    // A second, much simpler lift than the detail modal's: the book rises and
    // holds while its options are showing, and only settles once the menu is
    // dismissed. Rotate is *previewed* while lifted (`previewDisplayMode`)
    // and committed on settle, which is what makes the neighbouring books
    // reflow then rather than under the open menu.
    @State private var arrangingBook: SavedGenerationSummary?
    @State private var arrangeLiftOffset: CGFloat = 0
    @State private var previewDisplayMode: ShelfDisplayMode?
    @State private var deleteCandidate: SavedGenerationSummary?
    /// Separate from `arrangingBook` on purpose: the menu has to disappear
    /// the instant the user taps away, but the book keeps its lifted-book
    /// identity (offset, shadow) until the settle animation has actually
    /// finished. Clearing `arrangingBook` up front instead made the offset
    /// snap to 0 rather than animate down.
    @State private var isArrangeMenuVisible = false
    private let arrangeLiftDistance: CGFloat = 18
    /// Height of `ImportHomeView`'s floating header controls (4pt top pad +
    /// a 44pt tap target), reserved at the top of the scroll content.
    static let headerControlsInset: CGFloat = 48
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
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        shelfHeader

                        ShelfImportJobsSection(manager: pdfImports)

                        if books.isEmpty {
                            emptyState
                                .frame(minHeight: max(0, geometry.size.height - 100))
                        } else {
                            shelf(for: geometry.size.width)
                        }
                    }
                    // Home draws its Settings/avatar controls as a floating
                    // overlay rather than a navigation bar (see
                    // ImportHomeView.headerControls), so the shelf reserves
                    // that height itself instead of inheriting a bar inset.
                    .padding(.top, Self.headerControlsInset)
                    // Keep only a small trailing inset so shelves can pass
                    // underneath the progressive blur and Add Books action.
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(selectedBook != nil || arrangingBook != nil)
                .allowsHitTesting(selectedBook == nil)
                .accessibilityHidden(selectedBook != nil)

                // Tap-anywhere-else dismissal for the arrange menu. Clear
                // rather than dimmed — the book stays the focus, and the
                // shelf behind it shouldn't read as modal.
                if isArrangeMenuVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { endArranging() }
                        .accessibilityLabel("Dismiss book options")
                        .zIndex(2)
                }

                if let arrangingBook, isArrangeMenuVisible {
                    BookArrangeMenu(
                        isSpine: (previewDisplayMode ?? arrangingBook.shelfDisplayMode) == .spine,
                        anchor: coverFrames[arrangingBook.id],
                        onRotate: toggleRotation,
                        onDelete: { deleteCandidate = arrangingBook })
                    .zIndex(3)
                }

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
            .onPreferenceChange(BookHeroFramePreferenceKey.self) { frames in
                heroFrames = frames
            }
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
        .confirmationDialog(
            "Delete “\(deleteCandidate?.title ?? "")”?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Book", role: .destructive) {
                guard let book = deleteCandidate else { return }
                deleteCandidate = nil
                // Not via `endArranging` — that would commit a pending
                // rotation onto a project whose files are about to go.
                var cleanup = Transaction(animation: nil)
                cleanup.disablesAnimations = true
                withTransaction(cleanup) {
                    isArrangeMenuVisible = false
                    previewDisplayMode = nil
                    arrangingBook = nil
                    arrangeLiftOffset = 0
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    library.delete(book)
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes its pages, any generated audio, and its cover. This can't be undone.")
        }
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
                    liftDistance: max(liftDistance, arrangeLiftDistance),
                    arrangingBookID: arrangingBook?.id,
                    arrangeLiftOffset: arrangeLiftOffset,
                    previewDisplayMode: previewDisplayMode,
                    coverFacedBookID: detailShowsCoverFace ? selectedBook?.id : nil,
                    onSelect: { book in presentDetail(for: book) },
                    onLongPress: { book in beginArranging(book) })
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
            Text("Tap Add Books below to add a PDF to your shelf.")
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

    // MARK: - Long-press arrange

    private func beginArranging(_ book: SavedGenerationSummary) {
        guard selectedBook == nil, !isDismissingDetail, arrangingBook == nil else { return }
        previewDisplayMode = nil
        var selection = Transaction(animation: nil)
        selection.disablesAnimations = true
        withTransaction(selection) { arrangingBook = book }
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72)) {
            arrangeLiftOffset = -arrangeLiftDistance
            isArrangeMenuVisible = true
        }
    }

    /// Only previews — the book redraws in the new orientation immediately
    /// but keeps its committed layout footprint, so nothing around it moves
    /// while the menu is still open. `endArranging` is what commits.
    private func toggleRotation() {
        guard let book = arrangingBook, isArrangeMenuVisible else { return }
        let current = previewDisplayMode ?? book.shelfDisplayMode
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
            previewDisplayMode = current == .cover ? .spine : .cover
        }
    }

    /// Settles the book back onto the shelf and, if Rotate was tapped,
    /// commits the new orientation — which changes its layout width and so
    /// reflows the rest of the row in the same animation.
    private func endArranging() {
        guard let book = arrangingBook, isArrangeMenuVisible else { return }
        let committedMode = previewDisplayMode

        withAnimation(.easeOut(duration: 0.12)) { isArrangeMenuVisible = false }

        guard !reduceMotion else {
            if let committedMode {
                library.updateShelfDisplayMode(committedMode, for: book.id)
            }
            arrangeLiftOffset = 0
            previewDisplayMode = nil
            arrangingBook = nil
            return
        }

        // Settle and commit together: the width change the commit causes is
        // exactly what makes the neighbouring books reflow, so both belong
        // in the same animation. `arrangingBook` is cleared only afterwards
        // — it's what keeps the lift offset applied to this book until the
        // settle has actually played out.
        withAnimation(
            .spring(response: 0.34, dampingFraction: 0.86),
            completionCriteria: .logicallyComplete
        ) {
            arrangeLiftOffset = 0
            if let committedMode {
                library.updateShelfDisplayMode(committedMode, for: book.id)
            }
        } completion: {
            var cleanup = Transaction(animation: nil)
            cleanup.disablesAnimations = true
            withTransaction(cleanup) {
                previewDisplayMode = nil
                arrangingBook = nil
            }
        }
    }

    private func presentDetail(for book: SavedGenerationSummary) {
        // `arrangingBook` matters here because a long press can leave the
        // Button's own tap to fire on release — without this the menu and
        // the detail modal would both open from one gesture.
        guard selectedBook == nil, !isDismissingDetail, arrangingBook == nil else { return }
        // The hero always flies from a full cover — a spine-out book turns
        // face-out first — so it starts from the cover-face frame, not the
        // narrow spine slot the book rests in.
        selectedCoverFrame = heroFrames[book.id] ?? coverFrames[book.id]
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
                // A spine-out book turns face-out while it hangs there, so
                // what the overlay takes over is already a cover — the modal
                // is a full cover, and flying a narrow spine into it read
                // wrong. A cover-out book's turn is a no-op.
                turnFaceOut(book) {
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
    }

    /// Turns a spine-out book face-out and calls back once it has actually
    /// finished. Uses `bookShelfRotationAnimation` so this completion lines
    /// up with the turn `BookShelfRow` really plays.
    private func turnFaceOut(
        _ book: SavedGenerationSummary, then continuation: @escaping () -> Void
    ) {
        guard book.shelfDisplayMode == .spine, !reduceMotion else {
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) { detailShowsCoverFace = true }
            continuation()
            return
        }
        withAnimation(bookShelfRotationAnimation, completionCriteria: .logicallyComplete) {
            detailShowsCoverFace = true
        } completion: {
            continuation()
        }
    }

    /// The reverse, for the way back down: the book is face-out in the shelf
    /// slot again, so turn it back to its spine before it settles.
    private func turnBackToShelfFace(
        _ book: SavedGenerationSummary, then continuation: @escaping () -> Void
    ) {
        guard book.shelfDisplayMode == .spine, !reduceMotion else {
            detailShowsCoverFace = false
            continuation()
            return
        }
        withAnimation(bookShelfRotationAnimation, completionCriteria: .logicallyComplete) {
            detailShowsCoverFace = false
        } completion: {
            continuation()
        }
    }

    private func dismissDetail(afterDismiss: (() -> Void)? = nil) {
        guard let dismissingBook = selectedBook, !isDismissingDetail else { return }
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
                    // Still lifted and still face-out here. Turn back to the
                    // spine first, then settle — the mirror of the way up.
                    turnBackToShelfFace(dismissingBook) {
                        withAnimation(settleAnimation, completionCriteria: .logicallyComplete) {
                            liftOffset = 0
                        } completion: {
                            completeShelfReturn(afterDismiss)
                        }
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
        detailShowsCoverFace = false
        completion?()
    }

    private func openSelectedBook() {
        guard let book = selectedBook else { return }
        dismissDetail {
            onOpenBook(book)
        }
    }
}

/// The import manager publishes page-by-page progress. Keeping that
/// observation in this child avoids rebuilding the shelf's measured covers.
private struct ShelfImportJobsSection: View {
    @ObservedObject var manager: PDFImportManager

    private var visibleJobs: [PDFImportJob] {
        manager.jobs.filter { $0.phase != .completed && $0.phase != .cancelled }
    }

    @ViewBuilder
    var body: some View {
        if !visibleJobs.isEmpty {
            VStack(spacing: 10) {
                ForEach(visibleJobs.prefix(2)) { job in
                    PDFImportJobCard(job: job, manager: manager)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
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
    let arrangingBookID: UUID?
    let arrangeLiftOffset: CGFloat
    let previewDisplayMode: ShelfDisplayMode?
    /// Forced face-out while the detail modal's hero owns this book.
    let coverFacedBookID: UUID?
    let onSelect: (SavedGenerationSummary) -> Void
    let onLongPress: (SavedGenerationSummary) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(books) { book in
                        bookItem(for: book)
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

    /// Split across three small functions rather than one chain: as a single
    /// expression this exceeded the type-checker's budget outright
    /// ("unable to type-check this expression in reasonable time"). Each
    /// piece here stays trivially inferrable.
    private func bookItem(for book: SavedGenerationSummary) -> some View {
        interactiveCover(for: book)
            // HStack siblings paint in order, so a book whose artwork
            // overflows its slot — a cover mid-turn is far wider than the
            // spine slot it sits in — is drawn *under* every book after it.
            // Both lifts need raising, not just the arrange one: tapping a
            // spine-out book turns it face-out for the modal hero, and that
            // wide cover was landing behind its right-hand neighbour.
            // `arrangingBookID` outlives the arrange menu, and
            // `liftedBookID` spans the modal's lift/turn and its turn/settle
            // on the way back, so between them they cover every frame where
            // a book is off the shelf.
            .zIndex(isRaised(book) ? 1 : 0)
            .background { frameReporter(for: book) }
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    /// Deliberately *not* a `Button`: a Button's own gesture recognizer
    /// claims the touch before any long press attached to it can resolve, so
    /// the menu never opened. A plain view with both gestures lets SwiftUI
    /// arbitrate them properly — quick release taps, hold opens the menu —
    /// and `presentDetail` guards the case where a release after the long
    /// press still fires the tap.
    private func interactiveCover(for book: SavedGenerationSummary) -> some View {
        shelfCover(for: book)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(book) }
            .onLongPressGesture(minimumDuration: 0.35) { onLongPress(book) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(book.title), \(book.pageCountLabel)")
            .accessibilityHint("Opens this book")
            .accessibilityAction(named: "Book options") { onLongPress(book) }
    }

    /// Whether this book is currently off the shelf, in either sense — being
    /// arranged, or lifted for the detail modal. Either way its artwork can
    /// overflow its slot and must paint above its neighbours.
    private func isRaised(_ book: SavedGenerationSummary) -> Bool {
        arrangingBookID == book.id || liftedBookID == book.id || coverFacedBookID == book.id
    }

    /// Publishes two frames per book: the real slot (anchors the arrange
    /// menu) and where its cover face sits (what the modal hero flies from).
    /// For a spine-out book those differ — see `BookHeroFramePreferenceKey`.
    private func frameReporter(for book: SavedGenerationSummary) -> some View {
        GeometryReader { proxy in
            let slot = proxy.frame(in: .named(bookShelfModalCoordinateSpace))
            let hero = CGRect(
                x: slot.minX, y: slot.minY,
                width: coverSize.width, height: slot.height)
            Color.clear
                .preference(key: BookCoverFramePreferenceKey.self, value: [book.id: slot])
                .preference(key: BookHeroFramePreferenceKey.self, value: [book.id: hero])
        }
    }

    /// The fixed layout slot with the turning book drawn into it.
    ///
    /// Every animation here has to be an explicit `.animation(_:value:)`:
    /// the row applies `.transaction { animation = nil }` per book, and only
    /// a value-scoped animation wins over that override — a plain
    /// `withAnimation` at the call site does not reach in here.
    private func slot(
        size layoutSize: CGSize, book: SavedGenerationSummary, angle: Double
    ) -> some View {
        Color.clear
            .frame(width: layoutSize.width, height: layoutSize.height)
            .animation(arrangeAnimation, value: layoutSize.width)
            // `.bottomLeading`, not `.bottom`: both faces hinge on the
            // slot's leading edge (see RotatingBookFaces). At rest each face
            // is exactly the slot's width, so this looks identical to
            // centering it.
            .overlay(alignment: .bottomLeading) {
                RotatingBookFaces(
                    coverURL: book.coverURL,
                    title: book.title,
                    coverSize: coverSize,
                    spineWidth: book.spineWidth,
                    angle: angle)
                    .animation(reduceMotion ? nil : rotationAnimation, value: angle)
            }
    }

    /// The book's *layout* footprint follows its committed mode only, while
    /// the artwork drawn into it follows the preview. That split is what lets
    /// a rotate read immediately on the lifted book without the rest of the
    /// row shifting under the open menu — the neighbours only move once
    /// `BookShelfView.endArranging` commits the mode and this frame changes.
    private func shelfCover(for book: SavedGenerationSummary) -> some View {
        let isArranging = arrangingBookID == book.id
        // A spine-out book turns face-out before the detail modal's hero
        // takes over, and back again on the way down — the modal shows a
        // full cover, so flying a narrow spine into it read wrong.
        let rendered: ShelfDisplayMode =
            coverFacedBookID == book.id
            ? .cover
            : ((isArranging ? previewDisplayMode : nil) ?? book.shelfDisplayMode)
        let layoutSize = size(for: book, mode: book.shelfDisplayMode)

        // 0 = cover face-on, 90 = spine face-on. The *angle* is what
        // animates — driving `RotatingBookFaces` off a continuous value
        // rather than swapping two discrete views is what lets the book
        // actually turn instead of blinking between faces.
        let angle: Double = rendered == .spine ? 90 : 0

        return slot(size: layoutSize, book: book, angle: angle)
            .opacity(hiddenBookID == book.id ? 0 : 1)
            .animation(.linear(duration: 0.001), value: hiddenBookID)
            .offset(y: liftedBookID == book.id ? liftOffset : 0)
            .animation(liftAnimation, value: liftOffset)
            .offset(y: isArranging ? arrangeLiftOffset : 0)
            .shadow(
                color: .black.opacity(isArranging ? 0.22 : 0),
                radius: isArranging ? 10 : 0,
                y: isArranging ? 6 : 0)
            .animation(arrangeAnimation, value: arrangeLiftOffset)
            .animation(arrangeAnimation, value: isArranging)
    }

    private var arrangeAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.84)
    }

    /// Enough life to read as a real flick of the wrist, damped enough that
    /// it doesn't overshoot far past edge-on (`RotatingBookFaces` fades a
    /// face out over its last degrees as a second line of defence). Shared
    /// with `BookShelfView`'s sequencing so its completion callbacks line up
    /// with what's actually on screen.
    private var rotationAnimation: Animation { bookShelfRotationAnimation }

    private func size(for book: SavedGenerationSummary, mode: ShelfDisplayMode) -> CGSize {
        switch mode {
        case .cover: return coverSize
        case .spine: return CGSize(width: book.spineWidth, height: coverSize.height)
        }
    }
}

/// The two-option menu a long press raises above the lifted book. Positioned
/// from the book's own measured frame (`BookCoverFramePreferenceKey`, which
/// the shelf already tracks for the detail-modal hero), clamped so it can't
/// run off either screen edge for a book at the end of a row.
private struct BookArrangeMenu: View {
    let isSpine: Bool
    let anchor: CGRect?
    let onRotate: () -> Void
    let onDelete: () -> Void

    private let menuWidth: CGFloat = 188
    private let gapAboveBook: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                option(
                    icon: .rotateCw,
                    title: isSpine ? "Lay Flat" : "Rotate",
                    role: .normal,
                    action: onRotate)

                Divider().frame(height: 26).overlay(BookShelfPalette.secondaryText.opacity(0.25))

                option(icon: .trash, title: "Delete", role: .destructive, action: onDelete)
            }
            .frame(width: menuWidth)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(BookShelfPalette.primaryText.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .position(position(in: geometry.size))
            .transition(.scale(scale: 0.88, anchor: .bottom).combined(with: .opacity))
        }
        .accessibilityElement(children: .contain)
    }

    private func option(
        icon: LucideIconName, title: String, role: OptionRole, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LucideIcon(icon, size: 17, color: role.tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(role.tint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private enum OptionRole {
        case normal, destructive

        var tint: Color {
            switch self {
            case .normal: return BookShelfPalette.primaryText
            case .destructive: return .red
            }
        }
    }

    /// Sits centered over the book and above it where there's room, flipping
    /// below only when the book is too close to the top of the shelf.
    private func position(in container: CGSize) -> CGPoint {
        guard let anchor else {
            return CGPoint(x: container.width / 2, y: container.height / 2)
        }
        let halfWidth = menuWidth / 2
        let x = min(max(anchor.midX, halfWidth + 12), container.width - halfWidth - 12)
        let above = anchor.minY - gapAboveBook - 30
        let y = above < 40 ? anchor.maxY + gapAboveBook + 30 : above
        return CGPoint(x: x, y: y)
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

/// Shared by `BookShelfView`'s sequencing and `BookShelfRow`'s own
/// `.animation(_:value:)` on the turn. They must be the same spec: the row's
/// value-scoped animation is what actually plays (it beats the row's
/// `.transaction { animation = nil }`), while the view's `withAnimation`
/// exists only for its completion callback — if the two differed, the next
/// step would fire before the turn had visually finished.
private let bookShelfRotationAnimation: Animation = .spring(
    response: 0.45, dampingFraction: 0.8)

/// Each book's real layout slot — spine-width for a spine-out book. Used to
/// anchor the long-press arrange menu over the book you actually pressed.
private struct BookCoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Where the book's *cover face* sits, which is what the detail modal's hero
/// flies from and back to. Separate from the slot frame above because a
/// spine-out book turns face-out before the hero starts: it occupies a full
/// cover's width from its slot's leading edge, not the narrow spine slot.
/// Handing the hero the spine frame instead made it fly out of a sliver.
private struct BookHeroFramePreferenceKey: PreferenceKey {
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
            pdfImports: app.pdfImports,
            readingStats: app.readingStats,
            isDetailPresented: .constant(false),
            onOpenBook: { _ in })
    }
}
