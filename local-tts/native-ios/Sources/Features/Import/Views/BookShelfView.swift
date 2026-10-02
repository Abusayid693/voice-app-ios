import LucideSwift
import SwiftUI
import UIKit

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
    @StateObject private var shelfLayout = BookShelfLayoutStore()
    /// Publishes structural additions/removals only. Each import tile observes
    /// its own progress object so page updates do not invalidate shelf geometry.
    @ObservedObject var importShelf: PDFImportShelfStore
    let pdfImports: PDFImportManager
    let readingStats: ReadingStatsStore
    @Binding var isDetailPresented: Bool
    let onOpenBook: (SavedGenerationSummary) -> Void
    /// Starts music-mode playback (`Features/Listening/`) without opening
    /// the reader — unlike `onOpenBook`, this doesn't wait for the modal's
    /// hero to fly back down first; the now-playing screen presents
    /// immediately and the modal dismisses underneath it.
    let onListen: (SavedGenerationSummary) -> Void

    @State private var selectedBook: SavedGenerationSummary?
    // Fraction of pages completed for the currently-open book's detail
    // modal — fetched once when it's presented (see presentDetail), not
    // observed reactively; a one-shot read matches this app's convention
    // for state a view merely reads on demand.
    @State private var selectedBookProgress: Double = 0
    @State private var selectedCoverFrame: CGRect?
    @State private var selectedFullCoverSize: CGSize?
    @State private var coverFrames: [UUID: CGRect] = [:]
    /// Full cover dimensions used while a narrow spine unfolds in flight.
    @State private var heroFrames: [UUID: CGRect] = [:]
    @State private var shelfFrames: [Int: CGRect] = [:]
    @State private var modalPhase: CGFloat = 0
    @State private var showsModalDetails = false
    @State private var isShelfCoverHidden = false
    @State private var isDismissingDetail = false
    @State private var hasReachedCoverDestination = false

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
    @State private var arrangeDrag: ShelfBookDrag?
    @State private var preparedDrag: ShelfBookDrag?
    // Hold identity without subscribing this entire shelf to finger-rate publications.
    @State private var dragMotion = BookShelfDragMotion()
    @State private var frozenDragRows: [[ShelfEntry]]?
    @State private var isSettlingDrag = false
    @State private var longPressDragID: UUID?
    @State private var editingShelfIndex: Int?
    @State private var shelfTitleDraft = ""
    @Environment(\.scenePhase) private var scenePhase
    private let arrangeLiftDistance: CGFloat = 18
    /// Height of `ImportHomeView`'s floating header controls (4pt top pad +
    /// a 44pt tap target), reserved at the top of the scroll content.
    static let headerControlsInset: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completedBooks: [SavedGenerationSummary] {
        library.savedGenerations
            .filter { $0.source == .pdf }
    }

    private var shelfEntries: [ShelfEntry] {
        let legacy = completedBooks
            .filter { $0.shelfOrder == nil }
            .sorted { $0.createdAt > $1.createdAt }
            .map { ShelfEntry(saved: $0, importing: nil) }
        let savedByID = Dictionary(uniqueKeysWithValues: completedBooks.map { ($0.id, $0) })
        var orderedByID: [UUID: ShelfEntry] = [:]

        for book in completedBooks where book.shelfOrder != nil {
            orderedByID[book.id] = ShelfEntry(saved: book, importing: nil)
        }
        for item in importShelf.items {
            orderedByID[item.id] = ShelfEntry(saved: savedByID[item.id], importing: item)
        }

        let ordered = orderedByID.values.sorted {
            if $0.shelfOrder == $1.shelfOrder { return $0.createdAt < $1.createdAt }
            return $0.shelfOrder < $1.shelfOrder
        }
        return legacy + ordered
    }

    private var shelfRows: [[ShelfEntry]] {
        if let frozenDragRows { return frozenDragRows }
        let entries = shelfEntries
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return shelfLayout.layout(for: entries.map(\.id)).map { $0.compactMap { byID[$0] } }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollView {
                    // Keep the artwork in the scroll content itself instead
                    // of attaching it with `.background`, which the platform
                    // scroll host can composite away. This preserves its
                    // visibility while letting it scroll with the shelf.
                    ZStack(alignment: .top) {
                        ShelfHalftoneBackdrop()

                        VStack(spacing: 0) {
                            shelfHeader

                            if shelfEntries.isEmpty {
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
                        .padding(
                            .top,
                            geometry.safeAreaInsets.top + Self.headerControlsInset
                        )
                        // Keep only a small trailing inset so shelves can pass
                        // underneath the progressive blur and Add Books action.
                        .padding(.bottom, 24)
                        .background(ShelfScrollLock(isLocked: arrangingBook != nil || selectedBook != nil))
                    }
                }
                .scrollIndicators(.hidden)
                // Let the 200pt halftone canvas begin at the physical top of
                // the display. The VStack's matching safe-area padding above
                // keeps the title and shelves at their existing positions.
                .ignoresSafeArea(edges: .top)
                .scrollDisabled(selectedBook != nil || arrangingBook != nil)
                .allowsHitTesting(selectedBook == nil)
                .accessibilityHidden(selectedBook != nil)

                if selectedBook == nil {
                    ShelfGlassLayer(frames: shelfFrames)
                }

                ShelfBottomBlur()
                    .frame(height: 120 + geometry.safeAreaInsets.bottom)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: geometry.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)

                // Tap-anywhere-else dismissal for the arrange menu. Clear
                // rather than dimmed — the book stays the focus, and the
                // shelf behind it shouldn't read as modal.
                if isArrangeMenuVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { endArranging() }
                        .allowsHitTesting(arrangeDrag == nil)
                        .accessibilityLabel("Dismiss book options")
                        .zIndex(2)
                }

                if let arrangingBook, !isSettlingDrag {
                    // The menu's backdrop intercepts taps, but a lifted book remains draggable.
                    if let frame = arrangeDrag?.sourceFrame ?? coverFrames[arrangingBook.id] {
                        Color.clear
                            .frame(width: max(frame.width, 44), height: frame.height)
                            .contentShape(Rectangle())
                            .position(x: frame.midX, y: frame.midY + arrangeLiftOffset)
                            .modifier(ShelfLiftDragGesture(
                                requiresLongPress: false,
                                onChanged: { updateArrangeDrag(for: arrangingBook, value: $0) },
                                onEnded: { finishArrangeDrag() },
                                onCancelled: { finishArrangeDrag(cancelled: true) }))
                            .accessibilityHidden(true)
                            .allowsHitTesting(isArrangeMenuVisible)
                            .zIndex(3)
                    }
                }
                if let arrangingBook, isArrangeMenuVisible {
                    ShelfArrangeOverlay(
                        motion: dragMotion,
                        book: arrangingBook,
                        mode: previewDisplayMode ?? arrangingBook.shelfDisplayMode,
                        drag: arrangeDrag,
                        preparedDrag: preparedDrag,
                        restingAnchor: coverFrames[arrangingBook.id]?.offsetBy(dx: 0, dy: arrangeLiftOffset),
                        onRotate: toggleRotation,
                        onDelete: { deleteCandidate = arrangingBook })
                    .zIndex(5)
                }

                if let selectedBook {
                    BookShelfDetailModal(
                        book: selectedBook,
                        sourceFrame: selectedCoverFrame,
                        sourceCoverSize: selectedFullCoverSize,
                        shelfFrames: shelfFrames,
                        phase: modalPhase,
                        showsCover: isShelfCoverHidden,
                        showsDetails: showsModalDetails,
                        progress: selectedBookProgress,
                        onLayoutReady: { beginDetailTravel(for: selectedBook) },
                        onDismiss: { dismissDetail() },
                        onRead: openSelectedBook,
                        onListen: startListening)
                    .zIndex(1)
                }
            }
            .accessibilityLabel("PDF book shelves")
            .coordinateSpace(name: bookShelfModalCoordinateSpace)
            .modifier(ShelfLiftDragGesture(
                onChanged: handleShelfLongPress,
                onEnded: {
                    guard longPressDragID != nil else { return }
                    longPressDragID = nil
                    finishArrangeDrag()
                },
                onCancelled: {
                    guard longPressDragID != nil else { return }
                    longPressDragID = nil
                    finishArrangeDrag(cancelled: true)
                }))
            .onPreferenceChange(BookCoverFramePreferenceKey.self) { frames in
                coverFrames = frames
            }
            .onPreferenceChange(BookHeroFramePreferenceKey.self) { frames in
                heroFrames = frames
            }
            .onPreferenceChange(ShelfGlassFramePreferenceKey.self) { frames in
                if selectedBook == nil { shelfFrames = frames }
            }
        }
        .background(BookShelfPalette.background.ignoresSafeArea())
        .onChange(of: shelfEntries.map(\.id), initial: true) { _, ids in
            if arrangeDrag == nil { shelfLayout.synchronize(ids) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, arrangeDrag != nil { finishArrangeDrag(cancelled: true) }
        }
        .onDisappear {
            resetArrangeDrag()
        }
        .alert("Shelf arrangement", isPresented: Binding(
            get: { shelfLayout.errorMessage != nil },
            set: { if !$0 { shelfLayout.errorMessage = nil } })
        ) {
            Button("OK") { shelfLayout.errorMessage = nil }
        } message: {
            Text(shelfLayout.errorMessage ?? "")
        }
        .alert("Rename Shelf", isPresented: Binding(
            get: { editingShelfIndex != nil },
            set: { if !$0 { editingShelfIndex = nil } })
        ) {
            TextField("Shelf name", text: $shelfTitleDraft)
            Button("Cancel", role: .cancel) { editingShelfIndex = nil }
            Button("Save") { saveShelfTitle() }
                .disabled(normalizedShelfTitle.isEmpty)
        } message: {
            Text("Choose a name for this shelf.")
        }
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
                selectedFullCoverSize = nil
                isDismissingDetail = false
            }
        }
    }

    private var shelfHeader: some View {
        ZStack {
            ShelfHeaderBackdrop(books: Array(completedBooks.prefix(3)))
                .frame(height: 160)
                .clipped()

            VStack(spacing: 3) {
                Text("My Shelf")
                    .font(.custom("EBGaramond-Italic", size: 36, relativeTo: .title))
                    .fontWeight(.medium)
                    .foregroundStyle(BookShelfPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)

                Text("\(shelfEntries.count) \(shelfEntries.count == 1 ? "book" : "books")")
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
                    shelfIndex: index,
                    shelfTitle: shelfLayout.title(for: index),
                    entries: row,
                    coverSize: coverSize,
                    spacing: coverSpacing,
                    shelfWidth: shelfWidth,
                    leadingContentInset: index == 0 ? 30 : 16,
                    hiddenBookID: arrangeDrag != nil ? arrangingBook?.id : (isShelfCoverHidden ? selectedBook?.id : nil),
                    liftDistance: arrangeLiftDistance,
                    arrangingBookID: arrangingBook?.id,
                    arrangeLiftOffset: arrangeLiftOffset,
                    previewDisplayMode: previewDisplayMode,
                    onCancelImport: pdfImports.cancel(id:),
                    onRetryImport: pdfImports.retry(id:),
                    onDeleteImport: pdfImports.delete(id:),
                    onImportSettled: importShelf.finishPresentation(id:),
                    onSelect: { book in presentDetail(for: book) },
                    onLongPress: { book in beginArranging(book) },
                    onRenameShelf: { beginRenamingShelf(index) },
                    onMove: moveBookAccessibly)
                .id(index)
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

    private var normalizedShelfTitle: String {
        shelfTitleDraft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func beginRenamingShelf(_ shelf: Int) {
        guard selectedBook == nil, arrangingBook == nil else { return }
        shelfTitleDraft = shelfLayout.title(for: shelf)
        editingShelfIndex = shelf
    }

    private func saveShelfTitle() {
        guard let shelf = editingShelfIndex else { return }
        let title = normalizedShelfTitle
        editingShelfIndex = nil
        _ = shelfLayout.renameShelf(at: shelf, to: title)
    }

    // Lift, spine turn, and travel share a spring; the card expands after arrival.
    private var translateAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.9)
    }

    private var expandAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.92)
    }

    // MARK: - Long-press arrange

    private func handleShelfLongPress(_ value: DragGesture.Value) {
        if longPressDragID == nil {
            guard selectedBook == nil,
                  let book = shelfEntries.first(where: {
                      $0.importing == nil && coverFrames[$0.id]?.contains(value.startLocation) == true
                  })?.saved,
                  arrangingBook == nil || (arrangingBook?.id == book.id && isArrangeMenuVisible) else { return }
            if arrangingBook == nil { beginArranging(book) }
            longPressDragID = book.id
        }
        if let book = arrangingBook, longPressDragID == book.id {
            updateArrangeDrag(for: book, value: value)
        }
    }

    private func updateArrangeDrag(for book: SavedGenerationSummary, value: DragGesture.Value) {
        guard arrangingBook?.id == book.id, isArrangeMenuVisible, !isSettlingDrag else { return }
        guard abs(value.translation.width) + abs(value.translation.height) > 6 else { return }
        if arrangeDrag == nil {
            guard let drag = makeArrangeDrag(for: book) else { return }
            frozenDragRows = shelfRows
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragMotion.track(translation: value.translation, location: value.location)
                arrangeDrag = drag
            }
            return
        }
        // Direct compositor translation follows the finger; no spring lag or shelf publication.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragMotion.track(translation: value.translation, location: value.location)
        }
    }

    private func makeArrangeDrag(for book: SavedGenerationSummary) -> ShelfBookDrag? {
        guard var frame = coverFrames[book.id], let coverSize = heroFrames[book.id]?.size else { return nil }
        frame.size.width = (previewDisplayMode ?? book.shelfDisplayMode) == .spine ? book.spineWidth : coverSize.width
        return ShelfBookDrag(
            sourceFrame: frame, coverSize: coverSize,
            liftedCenter: CGPoint(x: frame.midX, y: frame.midY - arrangeLiftDistance))
    }

    private func finishArrangeDrag(cancelled: Bool = false) {
        guard let drag = arrangeDrag, let book = arrangingBook, !isSettlingDrag else { return }
        let oldRows = shelfRows
        let location = dragMotion.location
        let destination = cancelled ? nil : dropShelf(at: location, coverHeight: drag.coverSize.height)
        isSettlingDrag = true

        withAnimation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
            completionCriteria: .removed
        ) {
            frozenDragRows = nil
            if let destination, oldRows.indices.contains(destination) {
                let candidates = oldRows[destination].filter { $0.id != book.id }
                let next = candidates.first { entry in
                    coverFrames[entry.id].map { $0.midX > location.x } ?? false
                }?.id ?? candidates.lastIndex(where: { coverFrames[$0.id] != nil }).flatMap { index in
                    candidates.indices.contains(index + 1) ? candidates[index + 1].id : nil
                }
                _ = shelfLayout.move(book.id, to: destination, before: next, orderedIDs: shelfEntries.map(\.id))
            }
            if let mode = previewDisplayMode,
               !library.updateShelfDisplayMode(mode, for: book.id) { previewDisplayMode = nil }

            let newRows = shelfRows
            if let row = newRows.firstIndex(where: { $0.contains(where: { $0.id == book.id }) }) {
                let target = landingCenter(for: book.id, row: row, oldRows: oldRows,
                                           newEntries: newRows[row], drag: drag)
                dragMotion.translation = CGSize(
                    width: target.x - drag.liftedCenter.x,
                    height: target.y - drag.liftedCenter.y)
            }
        } completion: {
            guard arrangingBook?.id == book.id else { return }
            resetArrangeDrag(keepLifted: true)
            shelfLayout.synchronize(shelfEntries.map(\.id))
        }
    }

    /// Compute the final slot once, so the cover and neighbors share one spring without a layout-delay timer.
    private func landingCenter(
        for id: UUID, row: Int, oldRows: [[ShelfEntry]], newEntries: [ShelfEntry], drag: ShelfBookDrag
    ) -> CGPoint {
        let oldEntries = oldRows.indices.contains(row) ? oldRows[row] : []
        func width(_ entry: ShelfEntry) -> CGFloat {
            guard entry.importing == nil, let saved = entry.saved, saved.shelfDisplayMode == .spine else {
                return drag.coverSize.width
            }
            return saved.spineWidth
        }
        let spacing: CGFloat = 12
        var originX: CGFloat = row == 0 ? 30 : 16
        var centerY = (shelfFrames[row]?.maxY ?? drag.sourceFrame.maxY + 10) - 10 - drag.coverSize.height / 2
        if let anchorIndex = oldEntries.firstIndex(where: { coverFrames[$0.id] != nil }),
           let anchor = coverFrames[oldEntries[anchorIndex].id] {
            originX = anchor.minX - oldEntries.prefix(anchorIndex).reduce(0) { $0 + width($1) + spacing }
            centerY = anchor.midY
        }
        guard let index = newEntries.firstIndex(where: { $0.id == id }) else { return drag.liftedCenter }
        let precedingWidth = newEntries.prefix(index).reduce(0) { $0 + width($1) + spacing }
        return CGPoint(x: originX + precedingWidth + width(newEntries[index]) / 2,
                       y: centerY - arrangeLiftDistance)
    }

    private func dropShelf(at location: CGPoint, coverHeight: CGFloat) -> Int? {
        shelfFrames
            .filter { _, frame in
                location.x >= frame.minX - 16 && location.x <= frame.maxX + 16
                    && location.y >= frame.minY - coverHeight - 40 && location.y <= frame.maxY + 32
            }
            .min { abs($0.value.midY - coverHeight / 2 - location.y)
                < abs($1.value.midY - coverHeight / 2 - location.y) }?.key
    }

    private func resetArrangeDrag(keepLifted: Bool = false) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            arrangeDrag = nil
            frozenDragRows = nil
            isSettlingDrag = false
            isArrangeMenuVisible = keepLifted
            arrangeLiftOffset = keepLifted ? -arrangeLiftDistance : 0
            previewDisplayMode = nil
            if keepLifted, let id = arrangingBook?.id {
                arrangingBook = library.savedGenerations.first(where: { $0.id == id })
                if arrangingBook == nil {
                    isArrangeMenuVisible = false
                    arrangeLiftOffset = 0
                }
            } else {
                arrangingBook = nil
            }
            preparedDrag = arrangingBook.flatMap { makeArrangeDrag(for: $0) }
            dragMotion.translation = .zero
            longPressDragID = nil
        }
    }

    private func moveBookAccessibly(_ book: SavedGenerationSummary, direction: ShelfMoveDirection) {
        guard arrangingBook == nil, selectedBook == nil,
              let row = shelfRows.firstIndex(where: { $0.contains(where: { $0.id == book.id }) }),
              let index = shelfRows[row].firstIndex(where: { $0.id == book.id }) else { return }
        var destination = row
        var next: UUID?
        switch direction {
        case .earlier:
            guard index > 0 else { return }
            next = shelfRows[row][index - 1].id
        case .later:
            guard index + 1 < shelfRows[row].count else { return }
            next = shelfRows[row].indices.contains(index + 2) ? shelfRows[row][index + 2].id : nil
        case .shelfAbove: destination -= 1
        case .shelfBelow: destination += 1
        }
        _ = shelfLayout.move(book.id, to: destination, before: next, orderedIDs: shelfEntries.map(\.id))
    }

    private func beginArranging(_ book: SavedGenerationSummary) {
        guard selectedBook == nil, !isDismissingDetail, arrangingBook == nil else { return }
        previewDisplayMode = nil
        var selection = Transaction(animation: nil)
        selection.disablesAnimations = true
        withTransaction(selection) {
            preparedDrag = makeArrangeDrag(for: book)
            arrangingBook = book
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72)) {
            arrangeLiftOffset = -arrangeLiftDistance
            isArrangeMenuVisible = true
        }
    }

    /// Only previews — the book redraws in the new orientation immediately
    /// but keeps its committed layout footprint, so nothing around it moves
    /// while the menu is still open. `endArranging` is what commits.
    private func toggleRotation() {
        guard let book = arrangingBook, isArrangeMenuVisible, arrangeDrag == nil else { return }
        let current = previewDisplayMode ?? book.shelfDisplayMode
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
            previewDisplayMode = current == .cover ? .spine : .cover
        }
    }

    /// Settles the book back onto the shelf and, if Rotate was tapped,
    /// commits the new orientation — which changes its layout width and so
    /// reflows the rest of the row in the same animation.
    private func endArranging() {
        guard let book = arrangingBook, isArrangeMenuVisible, arrangeDrag == nil else { return }
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
        // Start from the actual shelf slot. A spine keeps its narrow visual
        // shape at progress zero and unfolds inside the travelling overlay.
        selectedCoverFrame = coverFrames[book.id] ?? heroFrames[book.id]
        selectedFullCoverSize = heroFrames[book.id]?.size ?? selectedCoverFrame?.size
        modalPhase = reduceMotion ? 2 : 0
        hasReachedCoverDestination = reduceMotion
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
            isShelfCoverHidden = reduceMotion
            selectedBook = book
            isDetailPresented = true
        }
    }

    private func beginDetailTravel(for book: SavedGenerationSummary) {
        guard !reduceMotion, selectedBook?.id == book.id,
            !isDismissingDetail, !isShelfCoverHidden else { return }
        var handoff = Transaction(animation: nil)
        handoff.disablesAnimations = true
        withTransaction(handoff) {
            isShelfCoverHidden = true
        }
        withAnimation(translateAnimation, completionCriteria: .logicallyComplete) {
            modalPhase = 1
        } completion: {
            guard selectedBook?.id == book.id, !isDismissingDetail else { return }
            hasReachedCoverDestination = true
            // Expand around the cover after it reaches its final slot.
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

    private func dismissDetail(afterDismiss: (() -> Void)? = nil) {
        guard selectedBook != nil, !isDismissingDetail else { return }
        isDismissingDetail = true

        if !reduceMotion, !hasReachedCoverDestination {
            withAnimation(translateAnimation, completionCriteria: .removed) {
                modalPhase = 0
            } completion: {
                completeShelfReturn(afterDismiss)
            }
            return
        }

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
                withAnimation(translateAnimation, completionCriteria: .removed) {
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
        selectedFullCoverSize = nil
        modalPhase = 0
        showsModalDetails = false
        isShelfCoverHidden = false
        isDismissingDetail = false
        hasReachedCoverDestination = false
        completion?()
    }

    private func openSelectedBook() {
        guard let book = selectedBook else { return }
        dismissDetail {
            onOpenBook(book)
        }
    }

    /// Unlike `openSelectedBook`, doesn't wait for the hero to fly back down
    /// first — the now-playing screen presents immediately and the modal
    /// dismisses underneath it, since starting music mode isn't a
    /// navigation the modal needs to get out of the way for.
    private func startListening() {
        guard let book = selectedBook else { return }
        onListen(book)
        dismissDetail()
    }
}

/// Softens shelf content beneath the floating bottom controls without a solid
/// footer — the bottom counterpart to `ShelfTopBlur`, same technique: one
/// masked `.ultraThinMaterial` band, not several stacked ones. Stacking
/// several masked-Material layers to fake a ramping blur *radius* was tried
/// here first and didn't read as blur at all — a masked `Material` mostly
/// contributes translucent tint once it isn't the one thing sitting directly
/// on live content, so four of them plus the paper wash on top just looked
/// like a flat gradient. One real blur band, same as the top edge.
///
/// The paper wash on top is still needed, though: unlike the top edge (which
/// only has to fade into the shelf), the bar's dark capsules need a light
/// ground to sit on, and blur alone still lets cover artwork read through at
/// the very bottom.
private struct ShelfBottomBlur: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5), .black],
                        startPoint: .top,
                        endPoint: .bottom))

            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.55), location: 0.55),
                    .init(color: .white, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Decorative artwork behind the top 200pt of the shelf. The mask keeps the
/// image fully visible around the title, then dissolves it into the paper
/// background instead of ending on a hard horizontal edge.
private struct ShelfHalftoneBackdrop: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "halftone", withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.58),
                    .init(color: .black.opacity(0.72), location: 0.74),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A restrained, decorative echo of the newest covers. It remains layered
/// above the halftone artwork and behind the title, preserving the original
/// Shelf header.
private struct ShelfHeaderBackdrop: View {
    let books: [SavedGenerationSummary]

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

private struct ShelfEntry: Identifiable {
    let saved: SavedGenerationSummary?
    let importing: PDFImportShelfItem?

    var id: UUID { saved?.id ?? importing!.id }
    var title: String { saved?.title ?? importing!.title }
    var createdAt: Date { saved?.createdAt ?? importing!.createdAt }
    var shelfOrder: Int { saved?.shelfOrder ?? importing?.shelfOrder ?? .max }
}

private struct BookShelfRow: View {
    let shelfIndex: Int
    let shelfTitle: String
    let entries: [ShelfEntry]
    let coverSize: CGSize
    let spacing: CGFloat
    let shelfWidth: CGFloat
    let leadingContentInset: CGFloat
    let hiddenBookID: UUID?
    let liftDistance: CGFloat
    let arrangingBookID: UUID?
    let arrangeLiftOffset: CGFloat
    let previewDisplayMode: ShelfDisplayMode?
    let onCancelImport: (UUID) -> Void
    let onRetryImport: (UUID) -> Void
    let onDeleteImport: (UUID) -> Void
    let onImportSettled: (UUID) -> Void
    let onSelect: (SavedGenerationSummary) -> Void
    let onLongPress: (SavedGenerationSummary) -> Void
    let onRenameShelf: () -> Void
    let onMove: (SavedGenerationSummary, ShelfMoveDirection) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: spacing) {
                    ForEach(entries) { entry in
                        entryItem(for: entry)
                            .id(entry.id)
                            .transition(.identity)
                    }
                }
                // Extra headroom above the covers equal to liftDistance —
                // ScrollView clips to its own bounds, and without this the
                // lifted cover's top edge crosses that clip line and gets
                // visibly cut off/jittery right at the peak of the lift.
                .padding(.top, 12 + liftDistance)
                .padding(.bottom, 10)
                .background(ShelfScrollLock(isLocked: arrangingBookID != nil))
            }
            .scrollDisabled(arrangingBookID != nil)
            .scrollIndicators(.hidden)
            // The glass shelf remains inset, while only the scroll viewport
            // extends to the screen edges so covers never clip at either end.
            .padding(.horizontal, -8)
            .contentMargins(.leading, leadingContentInset, for: .scrollContent)
            .contentMargins(.trailing, 16, for: .scrollContent)

            Color.clear
                .frame(
                    width: shelfWidth,
                    height: 18)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ShelfGlassFramePreferenceKey.self,
                            value: [shelfIndex: proxy.frame(in: .named(bookShelfModalCoordinateSpace))])
                    }
                }
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRenameShelf) {
                HStack(spacing: 5) {
                    Text(shelfTitle)
                        .lineLimit(1)
                    LucideIcon(.pencil, size: 12, color: BookShelfPalette.secondaryText.opacity(0.72))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BookShelfPalette.secondaryText)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(arrangingBookID != nil)
            .padding(.trailing, 4)
            .accessibilityLabel("Rename \(shelfTitle) shelf")
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
    @ViewBuilder
    private func entryItem(for entry: ShelfEntry) -> some View {
        if let importing = entry.importing {
            PDFImportShelfCover(
                item: importing,
                size: coverSize,
                liftDistance: 15,
                onCancel: { onCancelImport(importing.id) },
                onRetry: { onRetryImport(importing.id) },
                onDelete: { onDeleteImport(importing.id) },
                onSettled: { onImportSettled(importing.id) })
            .zIndex(1)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BookCoverFramePreferenceKey.self,
                        value: [entry.id: proxy.frame(in: .named(bookShelfModalCoordinateSpace))])
                }
            }
        } else if let book = entry.saved {
            bookItem(for: book)
        }
    }

    private func bookItem(for book: SavedGenerationSummary) -> some View {
        interactiveCover(for: book)
            .zIndex(isRaised(book) ? 1 : 0)
            .background { frameReporter(for: book) }
    }

    /// Show options on hold; the viewport owns the drag so lazy row reuse cannot cancel it.
    private func interactiveCover(for book: SavedGenerationSummary) -> some View {
        shelfCover(for: book)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(book) }
            .onLongPressGesture(minimumDuration: 0.35) { onLongPress(book) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(book.title), \(book.pageCountLabel)")
            .accessibilityHint("Opens this book. Hold to show options, then drag to move it.")
            .accessibilityAction(named: "Book options") { onLongPress(book) }
            .accessibilityAction(named: "Move earlier") { onMove(book, .earlier) }
            .accessibilityAction(named: "Move later") { onMove(book, .later) }
            .accessibilityAction(named: "Move to shelf above") { onMove(book, .shelfAbove) }
            .accessibilityAction(named: "Move to shelf below") { onMove(book, .shelfBelow) }
    }

    private func isRaised(_ book: SavedGenerationSummary) -> Bool {
        arrangingBookID == book.id
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

    /// Layout reflows only on commit; rotation remains a visual preview while lifted.
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
                    spineArtworkURL: book.spineArtworkURL,
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
        let rendered = (isArranging ? previewDisplayMode : nil) ?? book.shelfDisplayMode
        let layoutSize = size(for: book, mode: book.shelfDisplayMode)

        // 0 = cover face-on, 90 = spine face-on. The *angle* is what
        // animates — driving `RotatingBookFaces` off a continuous value
        // rather than swapping two discrete views is what lets the book
        // actually turn instead of blinking between faces.
        let angle: Double = rendered == .spine ? 90 : 0

        return slot(size: layoutSize, book: book, angle: angle)
            .opacity(hiddenBookID == book.id ? 0 : 1)
            .animation(.linear(duration: 0.001), value: hiddenBookID)
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

    /// Drives only the shelf's long-press arrangement preview.
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
struct BookArrangeMenu: View {
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

private struct BookShelfDetailModal: View, Animatable {
    let book: SavedGenerationSummary
    let sourceFrame: CGRect?
    let sourceCoverSize: CGSize?
    let shelfFrames: [Int: CGRect]
    var phase: CGFloat
    let showsCover: Bool
    let showsDetails: Bool
    // Fraction of pages completed, 0...1 — fetched once by BookShelfView
    // when this modal is presented; see coverProgressBar.
    let progress: Double
    let onLayoutReady: () -> Void
    let onDismiss: () -> Void
    let onRead: () -> Void
    let onListen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalContentHeight: CGFloat = 0
    @State private var measuredCoverFrame: CGRect = .zero
    private let dismissDragThreshold: CGFloat = 80
    private let expandedCoverSize = CGSize(width: 117.6, height: 176.4)
    /// Keeps the travelling book visibly above the glass shelf at both ends
    /// of the trip. A direct interpolation can initially move downward when
    /// the screen center is below the source book, which reads as the cover
    /// passing through the shelf instead of lifting clear of it.
    private let travelLiftDistance: CGFloat = 28

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = heroMetrics(in: geometry)

            ZStack {
                ShelfGlassLayer(frames: shelfFrames)
                    .zIndex(metrics.isBehindShelf ? 1 : -1)

                Color.black.opacity(0.28 * metrics.translationProgress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityLabel("Dismiss book details")
                    .transition(reduceMotion ? .opacity : .identity)

                detailCard(
                    targetWidth: metrics.targetWidth,
                    targetHeight: resolvedCardHeight(in: geometry))
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
                    .opacity(showsCover && metrics.expansionProgress > 0 ? 1 : 0)
                    .allowsHitTesting(showsDetails)
                    .transition(reduceMotion ? .opacity : .identity)
                    .gesture(dragToDismissGesture)
                    .accessibilityElement(children: .contain)

                heroCover(metrics: metrics)
                    .position(metrics.coverCenter)
                    .shadow(
                        color: .black.opacity(0.16 * metrics.expansionProgress),
                        radius: 12 * metrics.expansionProgress,
                        y: 6 * metrics.expansionProgress)
                    .opacity(showsCover && !showsDetails ? 1 : 0)
                    .animation(nil, value: showsDetails)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                // Measure the full content independently of the animated crop.
                modalContent(isMeasuring: true)
                    .frame(width: metrics.targetWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .coordinateSpace(name: "book-detail-measurement")
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        var measurement = Transaction(animation: nil)
                        measurement.disablesAnimations = true
                        withTransaction(measurement) { modalContentHeight = height }
                    }
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: modalContentHeight > 0 && measuredCoverFrame.height > 0) {
            if modalContentHeight > 0 && measuredCoverFrame.height > 0 { onLayoutReady() }
        }
    }

    @ViewBuilder
    private func heroCover(metrics: BookHeroMetrics) -> some View {
        if book.shelfDisplayMode == .spine {
            RotatingBookFaces(
                coverURL: book.coverURL,
                title: book.title,
                coverSize: metrics.coverSize,
                spineWidth: book.spineWidth,
                spineArtworkURL: book.spineArtworkURL,
                angle: metrics.coverAngle)
                .frame(
                    width: metrics.coverSize.width,
                    height: metrics.coverSize.height,
                    alignment: .bottomLeading)
        } else {
            SavedProjectCover(
                coverURL: book.coverURL,
                title: book.title,
                size: metrics.coverSize,
                cornerRadius: metrics.coverCornerRadius)
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
        targetHeight: CGFloat
    ) -> some View {
        Group {
            if modalContentHeight > targetHeight {
                ScrollView(.vertical, showsIndicators: false) {
                    modalContent()
                }
            } else {
                modalContent()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: targetWidth, height: targetHeight, alignment: .top)
        .background {
            modalBackground
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

    private var modalBackground: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                BookShelfPalette.background

                SavedProjectCover(
                    coverURL: book.coverURL,
                    title: book.title,
                    size: CGSize(
                        width: geometry.size.width + 72,
                        height: geometry.size.height / 2 + 72),
                    cornerRadius: 0)
                    .blur(radius: 28, opaque: true)
                    .offset(y: -36)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height / 2)
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.72),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom)
                    }
                    .opacity(showsDetails ? 0.58 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func heroMetrics(in geometry: GeometryProxy) -> BookHeroMetrics {
        let targetWidth = max(1, min(geometry.size.width - 32, 380))
        let resolvedSourceFrame = sourceFrame ?? CGRect(
            x: geometry.size.width / 2 - 45,
            y: geometry.size.height / 2 - 67.5,
            width: 90,
            height: 135)
        let resolvedSourceCoverSize = sourceCoverSize ?? resolvedSourceFrame.size
        let targetHeight = resolvedCardHeight(in: geometry)
        let translationProgress = reduceMotion ? 1 : min(max(phase, 0), 1)
        let expansionProgress = reduceMotion ? 1 : min(max(phase - 1, 0), 1)
        let screenCenter = CGPoint(
            x: geometry.size.width / 2,
            y: geometry.size.height / 2)
        // The hero lands in the measured content slot, including Dynamic Type layout.
        let finalCoverCenter = CGPoint(
            x: screenCenter.x - targetWidth / 2 + measuredCoverFrame.midX,
            y: screenCenter.y - targetHeight / 2 + measuredCoverFrame.midY)
        let sourceCoverCenter = CGPoint(
            x: resolvedSourceFrame.minX + resolvedSourceCoverSize.width / 2,
            y: resolvedSourceFrame.midY)
        let effectiveTravelLift = travelLiftDistance
            + max(finalCoverCenter.y - sourceCoverCenter.y, 0) * 0.3
        let clearanceProgress = shelfClearanceProgress(
            sourceFrame: resolvedSourceFrame,
            sourceCenter: sourceCoverCenter,
            destination: finalCoverCenter,
            sourceHeight: resolvedSourceCoverSize.height,
            lift: effectiveTravelLift)
        // Land directly in the final cover slot; expansion never moves it again.
        let coverCenter = reduceMotion
            ? finalCoverCenter
            : cubicPoint(
                from: sourceCoverCenter,
                firstControl: CGPoint(
                    x: sourceCoverCenter.x,
                    y: sourceCoverCenter.y - effectiveTravelLift),
                secondControl: CGPoint(
                    x: finalCoverCenter.x,
                    y: finalCoverCenter.y - effectiveTravelLift),
                to: finalCoverCenter,
                progress: translationProgress)
        let cardCenter = CGPoint(
            x: interpolate(
                from: finalCoverCenter.x,
                to: screenCenter.x,
                progress: expansionProgress),
            y: interpolate(
                from: finalCoverCenter.y,
                to: screenCenter.y,
                progress: expansionProgress))

        return BookHeroMetrics(
            targetWidth: targetWidth,
            translationProgress: translationProgress,
            expansionProgress: expansionProgress,
            cardSize: CGSize(
                width: interpolate(
                    from: expandedCoverSize.width,
                    to: targetWidth,
                    progress: expansionProgress),
                height: interpolate(
                    from: expandedCoverSize.height,
                    to: targetHeight,
                    progress: expansionProgress)),
            cardCenter: cardCenter,
            cornerRadius: interpolate(from: 3, to: 28, progress: expansionProgress),
            coverSize: CGSize(
                width: interpolate(
                    from: resolvedSourceCoverSize.width,
                    to: expandedCoverSize.width,
                    progress: translationProgress),
                height: interpolate(
                    from: resolvedSourceCoverSize.height,
                    to: expandedCoverSize.height,
                    progress: translationProgress)),
            coverCenter: coverCenter,
            coverCornerRadius: interpolate(from: 3, to: 8, progress: translationProgress),
            coverAngle: book.shelfDisplayMode == .spine
                ? 90 * Double(1 - translationProgress)
                : 0,
            isBehindShelf: !reduceMotion && translationProgress < clearanceProgress)
    }

    /// Use the first clearance point, so passing another shelf never hides the book again.
    private func shelfClearanceProgress(
        sourceFrame: CGRect,
        sourceCenter: CGPoint,
        destination: CGPoint,
        sourceHeight: CGFloat,
        lift: CGFloat
    ) -> CGFloat {
        guard let lip = shelfFrames.values.first(where: {
            $0.minY <= sourceFrame.maxY && $0.maxY >= sourceFrame.maxY
        }) else { return 0 }

        for step in 0...32 {
            let progress = CGFloat(step) / 64
            let center = cubicPoint(
                from: sourceCenter,
                firstControl: CGPoint(x: sourceCenter.x, y: sourceCenter.y - lift),
                secondControl: CGPoint(x: destination.x, y: destination.y - lift),
                to: destination,
                progress: progress)
            let height = interpolate(
                from: sourceHeight, to: expandedCoverSize.height, progress: progress)
            if center.y + height / 2 <= lip.minY - 2 { return progress }
        }
        return 0.5
    }

    private func resolvedCardHeight(in geometry: GeometryProxy) -> CGFloat {
        let maximumHeight = max(1, min(geometry.size.height - 32, 650))
        return modalContentHeight > 0 ? min(modalContentHeight, maximumHeight) : maximumHeight
    }

    private func modalContent(isMeasuring: Bool = false) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                coverProgressBar
                    .opacity(showsDetails ? 1 : 0)

                Color.clear
                    .frame(width: expandedCoverSize.width, height: expandedCoverSize.height)
                    .background {
                        if isMeasuring {
                            Color.clear
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    proxy.frame(in: .named("book-detail-measurement"))
                                } action: { frame in
                                    var measurement = Transaction(animation: nil)
                                    measurement.disablesAnimations = true
                                    withTransaction(measurement) { measuredCoverFrame = frame }
                                }
                        }
                    }
                    .overlay {
                        if !isMeasuring {
                            SavedProjectCover(
                                coverURL: book.coverURL,
                                title: book.title,
                                size: expandedCoverSize,
                                cornerRadius: book.shelfDisplayMode == .spine ? 3 : 8)
                                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                                .opacity(showsDetails ? 1 : 0)
                                .animation(nil, value: showsDetails)
                        }
                    }
            }

            VStack(spacing: 18) {
                Text(book.title)
                    .font(.custom("Inter", size: 22, relativeTo: .title2).weight(.medium))
                    .foregroundStyle(BookShelfPalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                VStack(spacing: 12) {
                    detailRow("Date added", value: book.createdAt.formatted(date: .abbreviated, time: .omitted))
                    detailRow("Pages", value: book.pageCountLabel)
                    detailRow("Estimated time", value: estimatedReadingTime)
                }
                .padding(.vertical, 2)

                HStack(spacing: 12) {
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

                    Button(action: onListen) {
                        LucideIcon(.headphones, size: 20, color: BookShelfPalette.primaryText)
                            .frame(width: 52, height: 52)
                            .background {
                                Circle().strokeBorder(BookShelfPalette.primaryText, lineWidth: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Listen")
                    .accessibilityHint("Starts continuous audio playback of this book")
                }
            }
            .opacity(showsDetails ? 1 : 0)
            .allowsHitTesting(showsDetails)
            .accessibilityHidden(!showsDetails)
        }
        .padding(.horizontal, 28)
        .padding(.top, 52)
        .padding(.bottom, 20)
    }

    // Real completed-pages fraction, matched to the expanded cover width.
    private var coverProgressBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.black.opacity(0.18))
                .overlay {
                    Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
                }
            Capsule()
                .fill(Color.black)
                .frame(width: expandedCoverSize.width * CGFloat(min(max(progress, 0), 1)))
        }
        .frame(width: expandedCoverSize.width, height: 3)
        .accessibilityHidden(true)
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }

    private func cubicPoint(
        from start: CGPoint,
        firstControl: CGPoint,
        secondControl: CGPoint,
        to end: CGPoint,
        progress: CGFloat
    ) -> CGPoint {
        let inverse = 1 - progress
        let startWeight = inverse * inverse * inverse
        let firstWeight = 3 * inverse * inverse * progress
        let secondWeight = 3 * inverse * progress * progress
        let endWeight = progress * progress * progress

        return CGPoint(
            x: start.x * startWeight
                + firstControl.x * firstWeight
                + secondControl.x * secondWeight
                + end.x * endWeight,
            y: start.y * startWeight
                + firstControl.y * firstWeight
                + secondControl.y * secondWeight
                + end.y * endWeight)
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

let bookShelfModalCoordinateSpace = "book-shelf-modal"

/// Explicit animation for the shelf row's arrangement preview.
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

/// Full cover geometry. A spine hero starts from the narrow slot above while
/// using this size for the cover face that unfolds during its flight.
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
    let coverAngle: Double
    let isBehindShelf: Bool
}

private struct ShelfGlassFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// One copy of each shelf lip; only lift-off and settling occlude the cover.
private struct ShelfGlassLayer: View {
    let frames: [Int: CGRect]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(frames.keys.sorted(), id: \.self) { index in
                if let frame = frames[index] {
                    GlassBookShelf()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        BookShelfView(
            library: app.library,
            importShelf: app.pdfImports.shelfStore,
            pdfImports: app.pdfImports,
            readingStats: app.readingStats,
            isDetailPresented: .constant(false),
            onOpenBook: { _ in },
            onListen: { _ in })
    }
}
