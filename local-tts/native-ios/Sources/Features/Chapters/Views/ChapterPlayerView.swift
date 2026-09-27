import Hugeicons
import LucideSwift
import SwiftUI
import UIKit

/// Uses exact scroll visibility on iOS 18+, with LazyVStack lifecycle as
/// the iOS 17 fallback. The fallback can retain a small prefetch margin,
/// but never reports an off-screen row before SwiftUI has actually retired
/// it from the lazy stack.
private struct ReaderScrollVisibilityObserver: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01, onChange)
        } else {
            content
                .onAppear { onChange(true) }
                .onDisappear { onChange(false) }
        }
    }
}


private enum ReaderPageNumberTransitionDirection: Equatable {
    case forward
    case backward
}

private struct PageNumberSlider: View {
    let value: Int
    let direction: ReaderPageNumberTransitionDirection
    /// Width of the digits. The view is this wide exactly — the fade is on
    /// the top and bottom edges, which is where the numbers travel.
    let width: CGFloat
    @State private var displayedValue: Int
    @State private var outgoingValue: Int?
    @State private var progress: CGFloat = 1

    /// Height the resting digits sit in, and the fade each side of it — so a
    /// number dissolves as it leaves rather than being cut off against a hard
    /// clip edge. The fade is *outside* `digitBoxHeight` rather than measured
    /// inward from the clip edge: digit ink nearly fills the resting box at
    /// this font, so an inward fade would permanently dim the numbers.
    private let digitBoxHeight: CGFloat = 24
    private let fadeInset: CGFloat = 5

    init(value: Int, direction: ReaderPageNumberTransitionDirection, width: CGFloat) {
        self.value = value
        self.direction = direction
        self.width = width
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        ZStack {
            if let outgoingValue {
                Text("\(outgoingValue)")
                    .offset(y: outgoingOffset)
            }

            Text("\(displayedValue)")
                .offset(y: incomingOffset)
        }
        .frame(width: width, height: totalHeight)
        .mask(edgeFade)
        .onChange(of: value) { _, newValue in
            animate(to: newValue)
        }
    }

    private var totalHeight: CGFloat { digitBoxHeight + fadeInset * 2 }

    /// Replaces a plain `.clipped()`: opaque across the resting digits,
    /// fading to clear over `fadeInset` at the top and bottom. Doubles as the
    /// clip, since anything past the edge is masked out entirely.
    private var edgeFade: some View {
        let fadeFraction = fadeInset / totalHeight
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fadeFraction),
                .init(color: .black, location: 1 - fadeFraction),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }

    /// Enough to clear the whole box it slides inside, fade included.
    private var travelDistance: CGFloat { totalHeight }

    /// Forward pushes the old number up and out the top, with the new one
    /// rising in from below; backward is the inverse — the number climbs as
    /// the page count does.
    private var outgoingOffset: CGFloat {
        let multiplier: CGFloat = direction == .forward ? -1 : 1
        return multiplier * travelDistance * progress
    }

    private var incomingOffset: CGFloat {
        let multiplier: CGFloat = direction == .forward ? 1 : -1
        return multiplier * travelDistance * (1 - progress)
    }

    private func animate(to newValue: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingValue = displayedValue
            displayedValue = newValue
            progress = 0
        }
        // A high-damping spring rather than an ease: it leaves at a gentler
        // rate than `easeInOut` and settles without a visible stop, which is
        // what makes the travel read as smooth over this short a distance.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.92)) {
            progress = 1
        }
    }
}

/// The page reader: one persisted page is visible at a time, with the
/// read-along transport floating above Previous/Next page navigation.
/// text, with a compact, translucent transport bar floating over its
/// bottom (elapsed/total time on top, avatar + −10s/play-pause/+10s
/// below) — text keeps scrolling underneath it, it doesn't reserve its own
/// space.
/// Opens at the project's saved page position (or page 1 when unavailable).
/// Playback is always synthesize-and-play (`chapterPlayer.stream`) — there
/// is no persisted "Generate" audio anymore (removed, see CHANGELOG), so
/// this view never asks which mode is active. `duration` is an *estimate*
/// of the current page's full length rather than a running sum of retained
/// audio (bounded lookahead means that sum would freeze at ~2 chunks'
/// worth), and seeking anywhere triggers on-demand synthesis rather than
/// being clamped — both handled inside `ChapterAudioPlayer`.
///
/// With continuous playback on, `ChapterAudioPlayer` can advance to the next
/// page on its own mid-session (prefetching across the boundary), which
/// this view observes via `chapterPlayer.activeRef` rather than driving —
/// see the `.onChange(of: chapterPlayer.activeRef)` handler, which updates
/// `currentPageIndex`/scroll position without the `stop()` a manually
/// requested page change goes through.
///
/// The read-along pauses auto-follow after any manual scroll and resumes it
/// only when the user taps the floating current-word pill. Highlighting is
/// word-level for English Kokoro
/// chunks (see `WordTimingDeriver`) — every chunk's own word-timings entry
/// drives this; an empty entry (non-English voice, a manifest saved before
/// this feature existed, or — during streaming — a chunk not yet
/// synthesized) falls back to highlighting the whole chunk, same as before.
struct ChapterPlayerView: View {
    let project: SavedGeneration
    let library: LibraryViewModel
    let previewPlayer: VoicePreviewPlayer
    let readingStats: ReadingStatsStore
    @ObservedObject var chapterPlayer: ChapterAudioPlayer
    @ObservedObject var viewModel: TTSViewModel

    @State private var currentPageIndex: Int
    @State private var currentPage: ReaderPage?
    @State private var idleChunkTexts: [String] = []
    @State private var selectedVoiceName: String
    @State private var pageNumberTransitionDirection: ReaderPageNumberTransitionDirection = .forward
    // Distinct pages with at least one completed listen, for this project —
    // feeds the page-picker tick and this header's own tick. Fetched off-
    // main via ReadingStatsStore, never a synchronous call; see
    // refreshCompletedPages().
    @State private var completedPageIndices: Set<Int> = []

    @State private var isAutoScrollPaused = false
    // Reference type, not @State: rows cross the scroll-visibility
    // threshold constantly during a flick, and as @State every one of
    // those crossings re-evaluated
    // this whole view — the entire ForEach over every paragraph — on top
    // of the 4Hz ticker and the 12.5Hz highlight poll already running.
    // That made scrolling-while-highlighting janky. Its only consumer is
    // the "jump to current word" pill, which polls (see readAlong's
    // overlay) rather than needing a publish.
    private final class VisibleParagraphsBox {
        var indices: Set<Int> = []
    }
    @State private var visibleParagraphsBox = VisibleParagraphsBox()
    private final class PageTurnGestureBox {
        var hasTurnedPage = false
    }
    // Reference-backed so a drag's per-frame bookkeeping does not invalidate
    // the full read-along layout.
    @State private var pageTurnGestureBox = PageTurnGestureBox()
    // Fixed once, so the TimelineViews below get a stable schedule value
    // instead of a fresh one built from `.now` on every body pass.
    @State private var pollAnchor = Date()
    // Chunks that belong to the same paragraph in the chapter's own source
    // text, grouped so they render as one continuous Text — one row per
    // paragraph, not one row per ~350-char synthesis chunk (see
    // computeParagraphGroups). Computed once on appear, not as a plain
    // computed property: body re-evaluates at 4Hz while playing
    // (chapterPlayer's ticker), and this does an O(n) string search over
    // the chapter text.
    @State private var paragraphGroups: [[Int]] = []
    /// One entry per paragraph group: the heading style the source document gave
    /// it, or nil for body text. Computed alongside `paragraphGroups` because it
    /// reuses the same chunk-to-page-text offsets.
    @State private var paragraphStyles: [ReaderTextStyle?] = []
    // Precomputed per-group word items (see wordItems(for:)) + a
    // per-group revision, both feeding ParagraphRow's Equatable
    // conformance — the actual fix for read-along scroll jank. Without
    // this, every group's words were rebuilt from scratch on every 4Hz
    // publish from chapterPlayer's ticker, whether or not that group's
    // content changed. Recomputed on appear and whenever a new chunk's
    // words become available (streaming — see the chapterPlayer.duration
    // onChange).
    //
    // Revisions are per group, not one shared counter: a streaming chunk
    // arrival changes exactly one paragraph's words, and a shared counter
    // would invalidate every paragraph in the chapter each time. The
    // O(words) content comparison that decides which revisions to bump
    // happens here, once per chunk — never in ParagraphRow's `==`, which
    // stays O(1) and runs on every publish.
    @State private var paragraphWordItems: [[FlowWordItem]] = []
    @State private var paragraphRevisions: [Int] = []
    // Monotonic, never reused: a revision's only job is to be *different*
    // from the value a row last rendered with, since ParagraphRow's `==`
    // deliberately doesn't compare `items`. Per-row counters that restart
    // at 0 (what this used to do on a group-count change) can hand a row
    // the same revision it already had alongside completely different
    // content — `==` then reports equal, SwiftUI skips the body, and the
    // row keeps rendering stale text until some unrelated compared field
    // changes. That's what made a paragraph render correctly and then
    // visibly collapse the moment playback reached it (flipping
    // isCurrentGroup was the unrelated change that finally forced a
    // rebuild).
    @State private var revisionCounter = 0
    // A spinning ring in the highlight color rings the play/pause button
    // while nothing is playable yet (chapterPlayer.isBuffering — true
    // entering the player before streaming's first chunk lands, or between
    // chunks if playback ever catches up to the synthesis frontier).
    @State private var isPulsingPlayButton = false
    @State private var isOptionsSheetPresented = false
    @State private var isPagePickerPresented = false
    @State private var isVoiceSelectionPresented = false
    @State private var isVoiceChangeErrorPresented = false
    // Persisted across sessions — set once, stays that way for every chapter
    // opened afterward. See the ⋯ menu (ChapterPlayerOptionsSheet).
    @AppStorage("chapterPlayerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("chapterPlayerShowFloatingPlayer") private var showFloatingPlayer = true
    @AppStorage("chapterPlayerAutoScrollEnabled") private var autoScrollEnabled = true
    // Off also stops the 12.5Hz poll that drives the highlight — the
    // paragraph-level box still marks where playback is.
    @AppStorage("chapterPlayerWordHighlightEnabled") private var wordHighlightEnabled = true
    @AppStorage("chapterPlayerFontSize") private var readerFontSize: ReaderFontSize = .medium
    @AppStorage("chapterPlayerFontFamily") private var readerFontFamily: ReaderFontFamily = .sfProText
    @AppStorage("chapterPlayerTheme") private var readerTheme: ReaderTheme = .carbon
    /// Shows the imported document's own page instead of the extracted text.
    /// Only reachable for PDF projects that kept a copy of their source.
    @AppStorage("chapterPlayerShowsOriginalPage") private var showsOriginalPage = false
    /// Whether playback advances into the next page on its own at the end of
    /// this one. Mirrored into `chapterPlayer` (which has no `@AppStorage` of
    /// its own) on appear and whenever it changes.
    @AppStorage("chapterPlayerContinuousPlayback") private var continuousPlaybackEnabled = true

    // The word a tap most recently resolved to, awaiting a second tap on its
    // "Play from here" confirm button — never acted on immediately, so a
    // mis-tap while reading doesn't jump playback. Tapping the same word
    // again clears it; tapping blank space (the background catcher in
    // readAlong) also clears it.
    private struct SelectedWordTarget: Equatable {
        let groupIndex: Int
        let itemIndex: Int
    }
    @State private var selectedWordTarget: SelectedWordTarget?
    // One WordFlowLayout.FrameBox per paragraph group, created lazily and
    // kept for the group's lifetime. Reference type, not a @State value —
    // frames land during layout, not on a meaningful content change, so
    // writing to the box must not itself invalidate the view (the same
    // reasoning as visibleParagraphsBox above).
    private final class ParagraphFrameBoxes {
        private var boxes: [Int: WordFlowLayout.FrameBox] = [:]
        func box(for groupIndex: Int) -> WordFlowLayout.FrameBox {
            if let existing = boxes[groupIndex] { return existing }
            let created = WordFlowLayout.FrameBox()
            boxes[groupIndex] = created
            return created
        }
    }
    @State private var paragraphFrameBoxes = ParagraphFrameBoxes()
    // Set just before assigning currentPageIndex from the activeRef handler
    // below, so the currentPageIndex onChange it triggers can tell a
    // continuous-playback advance (content already swapped, nothing further
    // to do) apart from every other, user-driven page change.
    @State private var isProgrammaticPageChange = false

    init(
        project: SavedGeneration, initialPageIndex: Int? = nil,
        library: LibraryViewModel,
        chapterPlayer: ChapterAudioPlayer,
        viewModel: TTSViewModel,
        previewPlayer: VoicePreviewPlayer,
        readingStats: ReadingStatsStore
    ) {
        self.project = project
        self.library = library
        self.previewPlayer = previewPlayer
        self.readingStats = readingStats
        _chapterPlayer = ObservedObject(wrappedValue: chapterPlayer)
        _viewModel = ObservedObject(wrappedValue: viewModel)
        let requestedIndex = initialPageIndex ?? project.lastReadPageIndex
        let hasValidRequestedIndex = project.pageCount > 0
            && (0..<project.pageCount).contains(requestedIndex)
        let boundedIndex = hasValidRequestedIndex ? requestedIndex : 0
        _currentPageIndex = State(initialValue: boundedIndex)
        _selectedVoiceName = State(initialValue: project.voiceName)
    }

    private var pageRef: ReaderPageRef {
        ReaderPageRef(projectID: project.id, pageIndex: currentPageIndex)
    }

    private var hasReadableText: Bool {
        !(currentPage?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var isCurrentKokoroPageActive: Bool {
        chapterPlayer.isActive(pageRef)
    }

    private var visibleChunkTexts: [String] {
        isCurrentKokoroPageActive && !chapterPlayer.chunkTexts.isEmpty
            ? chapterPlayer.chunkTexts : idleChunkTexts
    }

    // Falls back to one group per chunk before .onAppear populates
    // paragraphGroups, so the very first render matches today's per-chunk
    // layout instead of showing nothing.
    private var effectiveGroups: [[Int]] {
        paragraphGroups.isEmpty ? visibleChunkTexts.indices.map { [$0] } : paragraphGroups
    }

    /// The project's own copy of the imported PDF, when it has one. Books
    /// imported before that copy existed return nil, which hides the control.
    private var sourcePDFURL: URL? {
        SavedGeneration.existingSourcePDFURL(id: project.id)
    }

    private var canShowOriginalPage: Bool { sourcePDFURL != nil }

    @ViewBuilder
    private var readingSurface: some View {
        if showsOriginalPage, let sourcePDFURL {
            ReaderPDFPageView(
                pdfURL: sourcePDFURL, pageIndex: currentPageIndex,
                highlights: currentChunkPageRects, theme: readerTheme)
                .padding(.horizontal, 12)
                .padding(.bottom, showFloatingPlayer ? 68 : 12)
        } else {
            readAlong
        }
    }

    var body: some View {
        readingSurface
            .safeAreaInset(edge: .bottom, spacing: 0) { pageNavigator }
            .background(readerTheme.background.ignoresSafeArea())
            // `.overlay`, not a shared ZStack with readAlong: `.safeAreaInset`
            // content composites on top of its own main view, so a ZStack
            // sibling of readAlong still painted *under* pageNavigator's
            // background wherever the pill's negative bottom padding dipped
            // into that region. An overlay applied after the inset is
            // guaranteed to draw on top of both.
            .overlay(alignment: .bottom) {
                if showFloatingPlayer, hasReadableText {
                    floatingPlayer.padding(.bottom, 11)
                }
            }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                animatedPageTitle
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if canShowOriginalPage { originalPageToolbarControl }
                Button {
                    isOptionsSheetPresented = true
                } label: {
                    LucideIcon(.ellipsis, color: readerTheme.primaryText)
                }
            }
        }
        .sheet(isPresented: $isOptionsSheetPresented) {
            ChapterPlayerOptionsSheet(
                keepScreenOn: $keepScreenOn,
                showFloatingPlayer: $showFloatingPlayer,
                autoScrollEnabled: $autoScrollEnabled,
                wordHighlightEnabled: $wordHighlightEnabled,
                continuousPlaybackEnabled: $continuousPlaybackEnabled,
                fontSize: $readerFontSize,
                fontFamily: $readerFontFamily,
                theme: $readerTheme)
        }
        .sheet(isPresented: $isPagePickerPresented) {
            ReaderPagePickerSheet(
                project: project, library: library, currentPageIndex: currentPageIndex,
                theme: readerTheme, completedPageIndices: completedPageIndices,
                onSelect: selectPage)
        }
        .sheet(isPresented: $isVoiceSelectionPresented) {
            VoiceSettingsSheet(
                viewModel: viewModel,
                packs: viewModel.packs,
                previewPlayer: previewPlayer,
                restrictedEngine: project.engine,
                selectedVoiceName: selectedVoiceName,
                onVoiceSelected: changeVoice)
        }
        .alert("Voice Couldn’t Be Changed", isPresented: $isVoiceChangeErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The project could not be updated. Your previous voice is still selected.")
        }
        .preferredColorScheme(readerTheme.colorScheme)
        .onChange(of: keepScreenOn) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: autoScrollEnabled) { _, isEnabled in
            if !isEnabled {
                isAutoScrollPaused = false
            }
        }
        // Bumped once per chunk landing (see ChapterAudioPlayer.synthesisRevision),
        // which is exactly when a paragraph's words need to upgrade from the
        // plain-text fallback to real word timings. Not a per-frame cost.
        // `duration` alone isn't reliable for this now that it's an estimate
        // that can occasionally recompute to the same value between two
        // arrivals — see that property's own doc comment.
        .onChange(of: chapterPlayer.synthesisRevision) { _, _ in
            if isCurrentKokoroPageActive { recomputeWordItems() }
        }
        // Grouping was computed only in .onAppear, so entering the player
        // before the chunker had run (chunkTexts still empty) left the whole
        // session on the per-chunk fallback, never grouped into paragraphs.
        .onChange(of: chapterPlayer.chunkTexts.count) { _, _ in
            if isCurrentKokoroPageActive {
                paragraphGroups = computeParagraphGroups()
                paragraphStyles = computeParagraphStyles(groups: effectiveGroups)
                recomputeWordItems()
            }
        }
        .onChange(of: currentPageIndex) { oldValue, newValue in
            guard oldValue != newValue else { return }
            // Content already swapped by the activeRef handler below when
            // this index change originated from continuous playback — this
            // handler only needs to consume the flag, not tear playback down
            // a second time.
            if isProgrammaticPageChange {
                isProgrammaticPageChange = false
                return
            }
            guard moveToPage(newValue) else {
                currentPageIndex = oldValue
                return
            }
            library.recordLastReadPage(index: newValue, for: project.id)
        }
        // The one signal that the player advanced *on its own* — a manual
        // page change always updates currentPageIndex first (selectPage/the
        // picker/the swipe), which stops playback and nils this out before
        // any new value lands, so activeRef and currentPageIndex briefly
        // disagreeing only ever means continuous playback just promoted to
        // the next page. Swaps in the new content without chapterPlayer
        // .stop(), which would end the very session that's continuing.
        .onChange(of: chapterPlayer.activeRef) { _, newRef in
            guard let newRef, newRef.projectID == project.id, newRef.pageIndex != currentPageIndex
            else { return }
            isProgrammaticPageChange = true
            pageNumberTransitionDirection = .forward
            currentPageIndex = newRef.pageIndex
            _ = loadPage(newRef.pageIndex)
            library.recordLastReadPage(index: newRef.pageIndex, for: project.id)
        }
        // ChapterAudioPlayer doesn't get a new @Published "just completed"
        // signal (would re-render every visible ParagraphRow on every
        // change) — reacting to isPlaying turning false already covers
        // every real stop, natural finish included, at no extra publish
        // cost.
        .onChange(of: chapterPlayer.isPlaying) { _, isPlaying in
            if !isPlaying { refreshCompletedPages() }
        }
        .onChange(of: continuousPlaybackEnabled) { _, newValue in
            chapterPlayer.setContinuousPlaybackEnabled(newValue)
        }
        .onAppear {
            isAutoScrollPaused = false
            refreshCompletedPages()
            chapterPlayer.configureContinuousPlayback(
                enabled: continuousPlaybackEnabled,
                nextPageProvider: { [library, project] index in
                    library.page(for: project, index: index)
                })
            _ = moveToPage(currentPageIndex)
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            chapterPlayer.stop()
            // Unconditional, not just "if keepScreenOn" — this is a
            // process-global flag, and leaving with the toggle on must not
            // keep the rest of the app from ever auto-locking.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Leading: choose-page and change-voice. Trailing: previous/next page.
    /// Every control is the same 40pt rounded square so the row reads as one
    /// set — the voice avatar is a circle because it's artwork rather than
    /// chrome, and Pages is an icon alone (its "Pages" label was the only
    /// text in the bar).
    private func pageBarButton(
        systemImage: String, label: String, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(
                    readerTheme.controlBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(readerTheme.primaryText)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func pageControlsRow() -> some View {
        HStack(spacing: 8) {
            pageBarButton(systemImage: "list.bullet", label: "Choose page") {
                refreshCompletedPages()
                isPagePickerPresented = true
            }

            voiceButton

            Spacer(minLength: 0)

            pageBarButton(
                systemImage: "chevron.left", label: "Previous page",
                isEnabled: currentPageIndex > 0
            ) {
                selectPage(currentPageIndex - 1)
            }

            pageBarButton(
                systemImage: "chevron.right", label: "Next page",
                isEnabled: currentPageIndex < project.pageCount - 1
            ) {
                selectPage(currentPageIndex + 1)
            }
        }
    }

    private var pageNavigator: some View {
        pageControlsRow()
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background {
            // A fixed `.frame(height:)` here fought `.ignoresSafeArea`: it
            // pinned the rectangle to an exact size instead of letting it
            // grow to the true screen edge, leaving a gap below it over the
            // home indicator. Growing the *top* edge with negative padding
            // instead leaves the default background sizing (which already
            // matches this bar and reaches the true bottom via
            // ignoresSafeArea below) alone, and only extends upward — same
            // "extend past your own bounds" move as ShelfTopBlur, just
            // facing the other way.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        colors: [
                            .clear, .black.opacity(0.18), .black.opacity(0.55),
                            .black.opacity(0.85), .black,
                        ],
                        startPoint: .top,
                        endPoint: .bottom)
                }
                .padding(.top, -84)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var animatedPageTitle: some View {
        HStack(spacing: 4) {
            Text("Page")

            PageNumberSlider(
                value: currentPageIndex + 1,
                direction: pageNumberTransitionDirection,
                width: pageNumberWidth)

            Text("of \(project.pageCount)")

            // The tick's slot is reserved whether or not it shows, and
            // mirrored on the leading side: this group is centred in the
            // nav bar, so a tick that changes the group's width would
            // re-centre the whole title and shift it sideways the moment a
            // page completed. Reserving both sides keeps it centred too,
            // rather than parked permanently left of centre.
            tickSlot.opacity(completedPageIndices.contains(currentPageIndex) ? 1 : 0)
        }
        .padding(.leading, tickSlotWidth + 4)
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(readerTheme.primaryText)
        // Tall enough for the slider's own fade margin, so the nav bar never
        // clips a travelling number back to a hard edge.
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Page \(currentPageIndex + 1) of \(project.pageCount)"
                + (completedPageIndices.contains(currentPageIndex) ? ", completed" : ""))
    }

    private var tickSlotWidth: CGFloat { 13 }

    private var tickSlot: some View {
        LucideIcon(.check, size: 13, color: readerTheme.primaryText)
            .frame(width: tickSlotWidth)
            .accessibilityHidden(true)
    }

    private var pageNumberWidth: CGFloat {
        max(24, CGFloat(String(max(project.pageCount, 1)).count) * 10)
    }

    private func refreshCompletedPages() {
        Task {
            completedPageIndices = await readingStats.completedPageIndices(forProject: project.id)
        }
    }

    private func selectPage(_ index: Int) {
        guard index != currentPageIndex, (0..<project.pageCount).contains(index) else { return }
        pageNumberTransitionDirection = index > currentPageIndex ? .forward : .backward
        withAnimation(.easeInOut(duration: 0.24)) {
            currentPageIndex = index
        }
    }

    /// Switches between the extracted text and the document's own page. Filled
    /// while original-page mode is on, so the control shows the current state
    /// rather than only what tapping it would do.
    private var originalPageToolbarControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsOriginalPage.toggle()
            }
        } label: {
            LucideIcon(
                showsOriginalPage ? .fileText : .file,
                color: showsOriginalPage ? readerTheme.controlAccent : readerTheme.primaryText)
        }
        .accessibilityLabel(showsOriginalPage ? "Show extracted text" : "Show original page")
    }

    private func changeVoice(_ voiceName: String) {
        guard voiceName != selectedVoiceName else { return }

        chapterPlayer.stop()
        isPulsingPlayButton = false

        guard library.updateVoice(voiceName, for: project.id) else {
            isVoiceChangeErrorPresented = true
            return
        }
        selectedVoiceName = voiceName
    }

    @discardableResult
    private func moveToPage(_ index: Int) -> Bool {
        chapterPlayer.stop()
        isPulsingPlayButton = false
        return loadPage(index)
    }

    /// The content swap alone, without stopping playback — what a
    /// continuous-playback advance needs (it's the session being
    /// continued), and what `moveToPage` layers the teardown on top of for
    /// every user-driven page change.
    @discardableResult
    private func loadPage(_ index: Int) -> Bool {
        guard let page = library.page(for: project, index: index) else { return false }
        isAutoScrollPaused = false
        visibleParagraphsBox = VisibleParagraphsBox()
        selectedWordTarget = nil
        paragraphFrameBoxes = ParagraphFrameBoxes()

        currentPage = page
        idleChunkTexts = KokoroTextChunker.chunk(page.text)
        paragraphGroups = computeParagraphGroups()
        paragraphStyles = computeParagraphStyles(groups: effectiveGroups)
        paragraphWordItems = []
        paragraphRevisions = []
        recomputeWordItems()
        return true
    }

    // Only fades the ring in/out now — its rotation is driven independently
    // by bufferingRingAngle(at:), so there's nothing to start/stop here.
    private func updatePlayButtonPulse(isBuffering: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            isPulsingPlayButton = isBuffering
        }
    }

    // One full turn per second, purely a function of the current time — see
    // the ring's own overlay for why this replaced a repeatForever state
    // animation.
    private func bufferingRingAngle(at date: Date) -> Double {
        let period = 1.0
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return (elapsed / period) * 360
    }

    private func recomputeWordItems() {
        let fresh = effectiveGroups.map { wordItems(for: $0) }
        guard fresh.count == paragraphWordItems.count else {
            // The group count changed — every row's content is now derived
            // from a different set of chunks, so stamp them all with one
            // fresh revision rather than resetting to 0, which could
            // collide with what a row last rendered.
            revisionCounter += 1
            paragraphWordItems = fresh
            paragraphRevisions = Array(repeating: revisionCounter, count: fresh.count)
            return
        }
        var revisions = paragraphRevisions
        for index in fresh.indices where fresh[index] != paragraphWordItems[index] {
            revisionCounter += 1
            revisions[index] = revisionCounter
        }
        paragraphWordItems = fresh
        paragraphRevisions = revisions
    }

    // Groups consecutive chunk indices that have no real break between
    // them (per computeChunkGaps) into one paragraph each.
    private func computeParagraphGroups() -> [[Int]] {
        let gaps = computeChunkGaps()
        guard !gaps.isEmpty else { return [] }
        var groups: [[Int]] = [[0]]
        for index in 1..<gaps.count {
            if gaps[index] {
                groups.append([index])
            } else {
                groups[groups.count - 1].append(index)
            }
        }
        return groups
    }

    // For each chunk after the first: does a real line/paragraph break
    // exist between it and the previous chunk in the chapter's own text?
    // `chunkTexts` only carries chunk boundaries from the ~350-char
    // synthesis budget, not paragraph structure, so this is the only way
    // to tell an artificial cut (author never put a break there) apart
    // from a real one. Locates each chunk as a literal substring of the
    // full chapter text, searching forward from the previous match so
    // ordering and repeated content resolve correctly, and checks whether
    // any newline falls in the gap between consecutive matches.
    private func computeChunkGaps() -> [Bool] {
        let texts = visibleChunkTexts
        guard let fullText = currentPage?.text, texts.count > 1 else {
            return Array(repeating: true, count: texts.count)
        }
        var gaps = [Bool](repeating: true, count: texts.count)
        let ranges = chunkRanges(in: fullText, texts: texts)
        for index in 1..<texts.count {
            // A chunk that couldn't be located leaves its boundary at the
            // default — fail safe to a normal gap rather than guessing.
            guard let range = ranges[index], let previous = ranges[index - 1] else { continue }
            // Three places the break can be, not one. `KokoroTextChunker`
            // trims chunks with `.whitespaces`, which excludes newlines
            // (CharacterSet.whitespaces is Unicode Zs + tab), so a
            // paragraph's newline usually rides along *inside* a chunk's
            // own text — and since chunk ranges are contiguous, the gap
            // between two matches is then empty. Checking only the gap
            // reported "no break" at every boundary, merging a whole
            // chapter into one paragraph group.
            gaps[index] =
                fullText[previous.upperBound..<range.lowerBound].contains(where: \.isNewline)
                || texts[index - 1].last?.isNewline == true
                || texts[index].first?.isNewline == true
        }
        return gaps
    }

    /// Where each synthesis chunk sits inside the page text, nil when it could
    /// not be located verbatim.
    ///
    /// This literal search works only because `KokoroTextChunker` keeps a chunk
    /// byte-identical to a slice of the page text — it trims with
    /// `.whitespaces`, which excludes newlines. Both paragraph-break detection
    /// and heading styling need these positions, so they share one walk.
    private func chunkRanges(
        in fullText: String, texts: [String]
    ) -> [Range<String.Index>?] {
        var ranges: [Range<String.Index>?] = []
        ranges.reserveCapacity(texts.count)
        var searchStart = fullText.startIndex
        for text in texts {
            guard let range = fullText.range(
                of: text, range: searchStart..<fullText.endIndex)
            else {
                ranges.append(nil)
                continue
            }
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// The source-page rectangles the chunk being spoken occupies, as fractions
    /// of the page — what original-page mode highlights.
    ///
    /// Line rects are recorded at import against `ReaderPage.text`, and chunks
    /// are slices of that same string, so this is the same offset lookup the
    /// heading styling does. Overlap rather than containment, because one chunk
    /// normally spans several source lines and starts mid-line.
    private var currentChunkPageRects: [CGRect] {
        guard let page = currentPage, !page.lineRects.isEmpty else { return [] }
        let texts = visibleChunkTexts
        let index = chapterPlayer.currentChunkIndex
        guard isCurrentKokoroPageActive, texts.indices.contains(index) else { return [] }
        let ranges = chunkRanges(in: page.text, texts: texts)
        guard ranges.indices.contains(index), let range = ranges[index] else { return [] }

        let start = page.text.distance(from: page.text.startIndex, to: range.lowerBound)
        let end = page.text.distance(from: page.text.startIndex, to: range.upperBound)
        return page.lineRects
            .filter { $0.start < end && $0.end > start }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    /// Matches each paragraph group against the page's stored heading ranges.
    ///
    /// A group qualifies only when it *starts* at a heading and is not
    /// materially longer than that heading. Both halves matter: the length guard
    /// is what stops a heading that accidentally merged with the paragraph
    /// following it from rendering that whole paragraph at title size, which is
    /// a far louder failure than missing a heading altogether.
    private func computeParagraphStyles(groups: [[Int]]) -> [ReaderTextStyle?] {
        guard let page = currentPage, !page.headings.isEmpty else {
            return Array(repeating: nil, count: groups.count)
        }
        let text = page.text
        let ranges = chunkRanges(in: text, texts: visibleChunkTexts)

        return groups.map { group in
            let located = group.compactMap { index -> Range<String.Index>? in
                ranges.indices.contains(index) ? ranges[index] : nil
            }
            guard let first = located.first, let last = located.last else { return nil }
            let start = text.distance(from: text.startIndex, to: first.lowerBound)
            let length = text.distance(from: first.lowerBound, to: last.upperBound)
            return page.headings.first { heading in
                heading.start == start
                    && Double(length) <= Double(heading.length) * 1.5 + 8
            }?.style
        }
    }

    // MARK: - Floating player

    /// One pill, no expanded state — ±10s either side of play/pause. The
    /// expanded card it replaced carried the voice avatar, the page controls
    /// and an elapsed/total readout; the first two moved into `pageNavigator`
    /// (which the card used to cover, hence the duplicate set it carried) and
    /// the readout is gone.
    private var floatingPlayer: some View {
        HStack(spacing: 2) {
            skipButton(icon: .rotateCcw, label: "10") {
                chapterPlayer.skipBackward()
            }

            playPauseButton

            skipButton(icon: .rotateCw, label: "10") {
                chapterPlayer.skipForward()
            }
        }
        .padding(.horizontal, 10)
        .background { playerBackground(cornerRadius: 34) }
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        // Absorbs taps on the pill's own padding so they don't fall through
        // to the read-along underneath it.
        .onTapGesture { }
        .padding(.bottom, 8)
        .offset(y: 25)
    }

    // Liquid Glass is only available on iOS 26+. Its tint follows the
    // active reader palette; older systems use the matching translucent
    // theme surface instead.
    @ViewBuilder
    private func playerBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(
                    .regular.tint(readerTheme.controlBackground),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(readerTheme.controlBackground)
        }
    }

    private var playPauseButton: some View {
        PlayPauseBounceButton(
            isPlaying: isCurrentKokoroPageActive && chapterPlayer.isPlaying,
            action: toggleKokoroPlayback
        ) { isPlaying in
            (isPlaying ? Hugeicons.pause : Hugeicons.play)
                .image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(readerTheme.primaryText)
                .frame(width: 44, height: 44)
        }
        // A hard reset (no bounce) whenever the page or voice changes —
        // both already call `chapterPlayer.stop()` first, so `isPlaying`
        // reads false the instant this identity change recreates the
        // button's state. See PlayPauseBounceButton's own doc comment.
        .id("\(currentPageIndex)-\(selectedVoiceName)")
        .accessibilityLabel(isCurrentKokoroPageActive && chapterPlayer.isPlaying ? "Pause" : "Play")
        .disabled(!hasReadableText)
        .overlay {
            if isPulsingPlayButton {
                // Date-driven, not a repeatForever state animation: the ring
                // only enters the tree once isPulsingPlayButton flips true,
                // a moment *after* the rotation used to start — a view that
                // wasn't mounted yet when a `withAnimation` began doesn't
                // retroactively animate with it, so it read one static
                // interpolated angle and sat there. Reading the wall clock
                // instead can't desync from when the view happens to mount.
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            readerTheme.wordHighlightBackground,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        // Inside the 64pt button, not around the whole pill —
                        // at 72pt (bigger than the button's own frame) nothing
                        // clipped it, so it visibly overflowed the pill.
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(bufferingRingAngle(at: context.date)))
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            updatePlayButtonPulse(
                isBuffering: isCurrentKokoroPageActive && chapterPlayer.isBuffering)
        }
        .onChange(of: chapterPlayer.isBuffering) { _, isBuffering in
            updatePlayButtonPulse(isBuffering: isCurrentKokoroPageActive && isBuffering)
        }
    }

    private func toggleKokoroPlayback() {
        guard let page = currentPage, hasReadableText else { return }
        if chapterPlayer.isActive(pageRef) {
            chapterPlayer.togglePlayPause()
        } else {
            chapterPlayer.stream(
                pageRef, page: page, voice: selectedVoiceName, bookTitle: project.title)
        }
    }

    private var voiceButton: some View {
        Button {
            presentVoiceSelection()
        } label: {
            Image(VoiceCoverArt.assetName(for: selectedVoiceName))
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change voice, currently \(selectedVoiceName)")
    }

    private func presentVoiceSelection() {
        if chapterPlayer.isActive(pageRef), chapterPlayer.isPlaying {
            chapterPlayer.togglePlayPause()
        }
        isVoiceSelectionPresented = true
    }

    // A plain rotate-arrow icon reads as "skip back/forward" once paired
    // with a duration; Lucide's vendored set has no dedicated "skip 10s"
    // glyph (checked directly, not assumed), so the count is overlaid
    // rather than invented as a new icon.
    private func skipButton(icon: LucideIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                LucideIcon(icon, size: 28, color: readerTheme.primaryText)
                Text(label)
                    .appText(.meta)
                    .foregroundStyle(readerTheme.secondaryText)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }


    // MARK: - Read-along text

    private var readAlong: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if currentPage == nil {
                        ProgressView()
                            .tint(readerTheme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if !hasReadableText {
                        VStack(spacing: 10) {
                            LucideIcon(.fileText, size: 32, color: readerTheme.secondaryText)
                            Text("This page has no selectable text.")
                                .appText(.body)
                                .foregroundStyle(readerTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding()
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(effectiveGroups.indices, id: \.self) { groupIndex in
                                paragraphRowView(groupIndex: groupIndex)
                                    .id(groupIndex)
                                    .modifier(
                                        ReaderScrollVisibilityObserver { isVisible in
                                            if isVisible {
                                                visibleParagraphsBox.indices.insert(groupIndex)
                                            } else {
                                                visibleParagraphsBox.indices.remove(groupIndex)
                                            }
                                        })
                            }
                        }
                        // Tapping a word is handled inside ParagraphRow, on
                        // the WordFlowLayout itself (see its own doc comment
                        // for why: it needs the tap in the same coordinate
                        // space its word frames are recorded in). This
                        // background sits behind every row, so it only ever
                        // catches a tap no row already claimed — the gaps
                        // between paragraphs — and clears a pending "Play
                        // from here" selection there.
                        .background(
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { selectedWordTarget = nil }
                        )
                        .padding()
                        .padding(
                            .bottom,
                            showFloatingPlayer ? 56 : 0)
                    }
                }
            }
            .id(currentPageIndex)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged(handleReaderDragChanged)
                    .onEnded(handleReaderDragEnded)
            )
            .onChange(of: chapterPlayer.currentChunkIndex) { _, chunkIndex in
                guard isCurrentKokoroPageActive, autoScrollEnabled, !isAutoScrollPaused else { return }
                guard let (groupIndex, anchor) = scrollTarget(forChunk: chunkIndex) else { return }
                withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
            }
            // Toggling the original-page view swaps this whole ScrollView out
            // and back (it's the other branch of `readingSurface`), so coming
            // back mounts a fresh one at the top while audio carries on
            // somewhere else. The onChange above can't cover it: a just-mounted
            // view doesn't fire it for a value that hasn't changed. Not gated
            // on autoScrollEnabled — this is restoring position on mount, not
            // following playback, and there is no prior scroll position left
            // to respect either way.
            .onAppear {
                guard isCurrentKokoroPageActive else { return }
                // One run loop later: at onAppear the LazyVStack hasn't laid
                // its rows out yet and scrollTo can silently no-op.
                Task { @MainActor in
                    guard let (groupIndex, anchor) = scrollTarget(
                        forChunk: chapterPlayer.currentChunkIndex)
                    else { return }
                    // Unanimated — animating a jump from the top of the page
                    // would be a long visible sweep, not a restore.
                    proxy.scrollTo(groupIndex, anchor: anchor)
                }
            }
            .overlay(alignment: .top) {
                // Both conditions here are @State that flip once per scroll,
                // not per scroll event. Whether the playing paragraph is
                // actually off-screen is checked INSIDE the poll instead,
                // since that reads visibleParagraphsBox, which deliberately
                // doesn't publish — see its declaration.
                if isCurrentKokoroPageActive, autoScrollEnabled, isAutoScrollPaused {
                    TimelineView(.periodic(from: pollAnchor, by: 0.08)) { _ in
                        if isCurrentParagraphOffscreen {
                            currentWordResumeButton {
                                isAutoScrollPaused = false
                                if let (groupIndex, anchor) = scrollTarget(
                                    forChunk: chapterPlayer.currentChunkIndex)
                                {
                                    withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }
        }
    }

    /// Pages turn on a horizontal swipe: left for the next page, right for
    /// the previous one.
    ///
    /// This replaced a 56pt vertical overscroll pull at the top/bottom of the
    /// page. Horizontal is the easier axis to own here — the read-along is a
    /// *vertical* ScrollView, so a sideways drag isn't a scroll it has to be
    /// told apart from, which is why this needs no overscroll condition at
    /// all. The dominance check still earns its keep against diagonal drags,
    /// and `hasTurnedPage` keeps one long swipe from paging repeatedly.
    private func handleReaderDragChanged(_ value: DragGesture.Value) {
        let translation = value.translation

        if abs(translation.width) < 12 {
            pageTurnGestureBox.hasTurnedPage = false
        }

        // A vertical drag is a scroll, and any scroll takes auto-scroll out
        // of the driver's seat until the jump pill is tapped.
        if abs(translation.height) > abs(translation.width),
           isCurrentKokoroPageActive, autoScrollEnabled, !isAutoScrollPaused
        {
            isAutoScrollPaused = true
        }

        guard !pageTurnGestureBox.hasTurnedPage else { return }
        guard abs(translation.width) > abs(translation.height) * 1.25,
              abs(translation.width) >= 60
        else { return }

        if translation.width < 0, currentPageIndex < project.pageCount - 1 {
            pageTurnGestureBox.hasTurnedPage = true
            selectPage(currentPageIndex + 1)
        } else if translation.width > 0, currentPageIndex > 0 {
            pageTurnGestureBox.hasTurnedPage = true
            selectPage(currentPageIndex - 1)
        }
    }

    private func handleReaderDragEnded(_: DragGesture.Value) {
        pageTurnGestureBox.hasTurnedPage = false
    }

    private var isCurrentParagraphOffscreen: Bool {
        guard isCurrentKokoroPageActive else { return false }
        guard let groupIndex = effectiveGroups.firstIndex(where: {
            $0.contains(chapterPlayer.currentChunkIndex)
        }) else { return false }
        return !visibleParagraphsBox.indices.contains(groupIndex)
    }

    private var currentSpokenWord: String {
        let timings = chapterPlayer.wordTimings(forChunk: chapterPlayer.currentChunkIndex)
        guard
            let wordIndex = chapterPlayer.currentWordIndex(atElapsed: chapterPlayer.currentPlaybackTime),
            timings.indices.contains(wordIndex)
        else { return "Current" }
        return timings[wordIndex].word
    }

    @ViewBuilder
    private func currentWordResumeButton(action: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                Button(action: action) { currentWordResumeLabel }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to current word: \(currentSpokenWord)")
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } else {
            Button(action: action) { currentWordResumeLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to current word: \(currentSpokenWord)")
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var currentWordResumeLabel: some View {
        Text(currentSpokenWord)
            .font(AppTextStyle.label.font)
            .foregroundStyle(readerTheme.highlightedText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                readerTheme.wordHighlightBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(6)
    }

    // A single-chunk group scrolls to .center, same as before grouping
    // existed. A multi-chunk (merged-paragraph) group scrolls to the
    // vertical point matching the playing chunk's own position within
    // that paragraph, so a couple-of-pages-long paragraph keeps following
    // playback through it instead of parking at the paragraph's midpoint.
    private func scrollTarget(forChunk chunkIndex: Int) -> (Int, UnitPoint)? {
        let groups = effectiveGroups
        guard let groupIndex = groups.firstIndex(where: { $0.contains(chunkIndex) }) else { return nil }
        let group = groups[groupIndex]
        guard group.count > 1, let positionInGroup = group.firstIndex(of: chunkIndex) else {
            return (groupIndex, .center)
        }
        let progress = Double(positionInGroup) / Double(group.count - 1)
        return (groupIndex, UnitPoint(x: 0, y: progress))
    }

    // Only the currently-playing paragraph polls (TimelineView at ~12Hz);
    // every other row is constructed fresh each time this is called (cheap
    // — a handful of scalar fields) but its body only actually re-runs when
    // ParagraphRow's Equatable comparison finds something changed. That's
    // the real fix for read-along scroll jank: previously every paragraph's
    // full word list rebuilt on every 4Hz publish from chapterPlayer's
    // ticker, whether or not that paragraph's content changed.
    private func paragraphRowView(groupIndex: Int) -> some View {
        let group = effectiveGroups[groupIndex]
        let items =
            paragraphWordItems.indices.contains(groupIndex)
            ? paragraphWordItems[groupIndex] : wordItems(for: group)
        let revision = paragraphRevisions.indices.contains(groupIndex) ? paragraphRevisions[groupIndex] : 0
        // Position only — NOT gated on isPlaying, so the chunk band and
        // its last-highlighted word stay put on pause instead of both
        // disappearing. What isPlaying actually decides is below: whether
        // this row needs to keep ticking to track a moving position.
        let isCurrentGroup = isCurrentKokoroPageActive
            && group.contains(chapterPlayer.currentChunkIndex)
        let hasAnyWordTimings = items.contains { $0.wordIndexInChunk != nil }
        let showsWordHighlight = wordHighlightEnabled && hasAnyWordTimings && isCurrentGroup
        let isPolling = showsWordHighlight && chapterPlayer.isPlaying

        // One view type whether or not this row is the playing one. Putting
        // the TimelineView inside an if/else made the playing row a
        // *different* view, so it was torn down and rebuilt — new
        // WordFlowLayout cache, full re-measure — every time the highlight
        // entered or left it, which in a LazyVStack shifts everything below
        // it. Only the tick interval varies now; a non-playing row's
        // schedule never fires in practice, and `.equatable()` still gates
        // the body either way.
        let selectedItemIndex =
            selectedWordTarget?.groupIndex == groupIndex ? selectedWordTarget?.itemIndex : nil

        return TimelineView(.periodic(from: pollAnchor, by: isPolling ? 0.08 : 3600)) { _ in
            ParagraphRow(
                items: items, itemsRevision: revision,
                highlightedChunkIndex: showsWordHighlight ? chapterPlayer.currentChunkIndex : nil,
                highlightedWordIndex: showsWordHighlight
                    ? chapterPlayer.currentWordIndex(atElapsed: chapterPlayer.currentPlaybackTime) : nil,
                currentChunkIndex: isCurrentGroup ? chapterPlayer.currentChunkIndex : nil,
                isCurrentGroup: isCurrentGroup,
                fontSize: readerFontSize,
                fontFamily: readerFontFamily,
                style: paragraphStyles.indices.contains(groupIndex)
                    ? paragraphStyles[groupIndex] : nil,
                theme: readerTheme,
                selectedItemIndex: selectedItemIndex,
                frameBox: paragraphFrameBoxes.box(for: groupIndex),
                onWordTap: { itemIndex in handleWordTap(groupIndex: groupIndex, itemIndex: itemIndex) },
                onConfirmPlay: { itemIndex in
                    handleConfirmPlay(groupIndex: groupIndex, itemIndex: itemIndex)
                }
            ).equatable()
        }
    }

    // Flows one paragraph group's words through WordFlowLayout, so a
    // paragraph the synthesis chunker had to cut for its ~350-char budget
    // still wraps and reads as continuous prose instead of breaking
    // mid-line at the cut — while still letting the single currently-
    // playing word carry its own rounded background highlight, which plain
    // Text concatenation can't do (no way to give one piece within a
    // `Text + Text` run its own background). All word text is one color at
    // full opacity; only the word background and the playing chunk's own
    // band signal position. Every word carries constant padding regardless of
    // highlight state — varying it would resize the word and reflow the
    // paragraph as the highlight moves, the construction-method-
    // consistency rule from the earlier pause/resume reflow fix.
    //
    // Equatable so paragraphRowView's `.equatable()` can skip re-running
    // body entirely for a paragraph nothing changed about — comparing only
    // scalar values and the two small preference enums below, not `items`
    // elementwise, which is what actually makes the check cheap.
    // `itemsRevision` is what catches real content changes, including the
    // nil→index transition when a streaming chunk's word timings land.
    private struct ParagraphRow: View, Equatable {
        let items: [FlowWordItem]
        let itemsRevision: Int
        let highlightedChunkIndex: Int?
        let highlightedWordIndex: Int?
        /// The chunk actually playing, independent of the word-highlight
        /// preference — `highlightedChunkIndex` goes nil when that's off or
        /// a chunk has no timings, but the playing chunk still needs its own
        /// background.
        let currentChunkIndex: Int?
        let isCurrentGroup: Bool
        let fontSize: ReaderFontSize
        let fontFamily: ReaderFontFamily
        /// The source document's own heading treatment for this paragraph, or
        /// nil for body text.
        let style: ReaderTextStyle?
        let theme: ReaderTheme
        /// Which word (index into `items`) is awaiting a confirming tap on
        /// its "Play from here" button, or nil. Part of `==`: it changes
        /// which button (if any) is visible, but never a word's measured
        /// size, so it stays out of `measurementVersion`.
        let selectedItemIndex: Int?
        /// Where each word actually landed, written by `WordFlowLayout`
        /// during placement and read back here to resolve a tap — see the
        /// gesture attached to `WordFlowLayout` below. Reference-type side
        /// channel, deliberately excluded from `==`: its contents change on
        /// every layout pass, which is not a reason to re-render.
        let frameBox: WordFlowLayout.FrameBox
        /// Reports which word a tap resolved to. Excluded from `==` — see
        /// `paragraphRowView`: a fresh closure every render is fine here,
        /// since it only ever captures this row's fixed `groupIndex` and
        /// reads `@State` fresh at call time regardless of which render's
        /// closure ends up wired to the gesture.
        let onWordTap: (Int) -> Void
        /// Fires when the visible "Play from here" button is tapped.
        let onConfirmPlay: (Int) -> Void

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.itemsRevision == rhs.itemsRevision && lhs.highlightedChunkIndex == rhs.highlightedChunkIndex
                && lhs.highlightedWordIndex == rhs.highlightedWordIndex
                && lhs.currentChunkIndex == rhs.currentChunkIndex && lhs.isCurrentGroup == rhs.isCurrentGroup
                && lhs.fontSize == rhs.fontSize && lhs.fontFamily == rhs.fontFamily
                && lhs.style == rhs.style && lhs.theme == rhs.theme
                && lhs.selectedItemIndex == rhs.selectedItemIndex
        }

        // The inputs that can change a word's measured size. Colors (which is
        // all the highlight changes) can't, so the ~12x/sec re-runs while this
        // paragraph plays reuse the measured sizes instead of re-measuring
        // every word each time. `style` belongs here as much as in `==`: it
        // scales the font, so leaving it out would hand WordFlowLayout's cache
        // body-sized measurements for heading-sized words.
        private var measurementVersion: Int {
            var hasher = Hasher()
            hasher.combine(itemsRevision)
            hasher.combine(fontSize)
            hasher.combine(fontFamily)
            hasher.combine(style)
            return hasher.finalize()
        }

        private var resolvedFont: Font {
            guard let style else { return fontSize.font(family: fontFamily) }
            return fontSize.font(family: fontFamily, scale: style.scale, bold: style.isBold)
        }

        var body: some View {
            WordFlowLayout(
                horizontalSpacing: 2, verticalSpacing: 2, paragraphExtraSpacing: 6,
                measurementVersion: measurementVersion, frameBox: frameBox
            ) {
                // items.indices, not Array(items.enumerated()) — the
                // latter allocates a fresh tuple array on every body run,
                // which for the playing paragraph is 12x/sec.
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    // `highlightedWordIndex != nil` is load-bearing, not
                    // belt-and-braces: both sides of the comparison below are
                    // `Int?`, so while a tapped-ahead chunk buffers — no
                    // timings yet, so every item's index and the highlighted
                    // one are all nil — `nil == nil` matched *every* word in
                    // the chunk and lit the whole thing in the word color.
                    let isHighlighted =
                        isCurrentGroup && item.chunkIndex == highlightedChunkIndex
                            && highlightedWordIndex != nil
                            && item.wordIndexInChunk == highlightedWordIndex
                    // A row is a paragraph *group*, which can be several
                    // chunks; backing the whole row lit every chunk in it at
                    // once. Backing only the playing chunk's words keeps the
                    // band on the chunk actually being spoken. Adjacent words
                    // touch (their 2pt horizontal padding abuts), so a small
                    // radius reads as one continuous band rather than pills.
                    let isCurrentChunk = item.chunkIndex == currentChunkIndex
                    Text(item.text)
                        .font(resolvedFont)
                        .foregroundStyle(isHighlighted ? theme.highlightedText : theme.primaryText)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(
                            isHighlighted
                                ? theme.wordHighlightBackground
                                : (isCurrentChunk ? theme.chunkHighlightBackground
                                    : (selectedItemIndex == index
                                        ? theme.chunkHighlightBackground.opacity(0.7) : Color.clear)),
                            in: RoundedRectangle(cornerRadius: isHighlighted ? 4 : 3))
                        .lineBreaksBefore(item.lineBreaksBefore)
                }
            }
            // Attached here, not on the row after its own padding: a tap's
            // `value.location` needs to land in the exact same coordinate
            // space `WordFlowLayout` recorded frames in, which is this
            // view's own bounds before any outer padding shifts them.
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard let index = resolveTappedItem(at: value.location) else { return }
                    onWordTap(index)
                }
            )
            .overlay(alignment: .topLeading) {
                if let selectedItemIndex, let frame = frameBox.frames[selectedItemIndex] {
                    playFromHereButton { onConfirmPlay(selectedItemIndex) }
                        .offset(x: frame.minX, y: frame.maxY + 4)
                        // A small rise-and-fade rather than a hard cut in
                        // either direction — `.move` composes with the
                        // static positioning offset above, adding a slide
                        // just for the in/out transition itself.
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: selectedItemIndex)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Padding kept even though the row no longer draws its own
            // background — dropping it would reflow every paragraph.
            .padding(6)
            // A heading needs air above it to read as opening a section rather
            // than as a loud first line. Scaled off how large the document made
            // it, and applied as a modifier on the same view — an if/else
            // around the row would change its structural identity and force a
            // re-measure of everything below it in the LazyVStack.
            .padding(.top, style.map { ($0.scale - 1) * 20 + 10 } ?? 0)
        }

        /// The word whose frame contains the tap, or — taps often land in
        /// the small gaps between words/lines — the nearest one.
        private func resolveTappedItem(at location: CGPoint) -> Int? {
            if let hit = frameBox.frames.first(where: { $0.value.contains(location) }) {
                return hit.key
            }
            guard !frameBox.frames.isEmpty else { return nil }
            return frameBox.frames.min {
                distanceSquared(from: location, to: $0.value)
                    < distanceSquared(from: location, to: $1.value)
            }?.key
        }

        private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }

        private func playFromHereButton(action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    // 70% of the 1.3x pass (14.3/18.2) — icon and font
                    // scaled together so the label still reads as one unit.
                    LucideIcon(.play, size: 10, color: theme.primaryText)
                    Text("Play from here")
                        .font(.system(size: 12.7, weight: .regular))
                        .foregroundStyle(theme.primaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background { playFromHereBackground }
            // Above the paragraph text and, since WordFlowLayout's own
            // frame otherwise clips to its measured size, wide enough that
            // the button isn't cut off against the row's right edge.
            .zIndex(1)
            .fixedSize()
        }

        // Liquid Glass on iOS 26+, matching the floating player's own
        // background; the translucent theme surface below that. Same
        // fallback pair as `ChapterPlayerView.playerBackground`.
        @ViewBuilder
        private var playFromHereBackground: some View {
            if #available(iOS 26.0, *) {
                // No tint — plain glass, not a colored pill.
                Color.clear.glassEffect(.regular, in: Capsule())
            } else {
                // Same untinted-material precedent as currentWordResumeButton's
                // own pre-26 fallback.
                Capsule().fill(.ultraThinMaterial)
            }
        }
    }

    // One entry per displayed word across a paragraph group's chunks,
    // flattening chunk boundaries away — WordFlowLayout wraps this exactly
    // like continuous prose. `wordIndexInChunk` is nil for a chunk with no
    // word timings (non-English voice, or — streaming — not yet
    // synthesized): its words still display via
    // WordTimingDeriver.splitPreservingSeparators (the same real-separator
    // splitter chunk text itself uses), they just can never be the
    // highlighted word, matching the whole-chunk-only fallback this had
    // before per-word highlighting existed.
    // Equatable so recomputeWordItems can tell which paragraphs actually
    // changed and bump only their revisions.
    private struct FlowWordItem: Equatable {
        let text: String
        let chunkIndex: Int
        let wordIndexInChunk: Int?
        /// This word's position within its chunk, always known — unlike
        /// `wordIndexInChunk`, which is nil until the chunk has real word
        /// timings. Both come from `splitPreservingSeparators`, the same
        /// splitter `WordTimingDeriver` derives timings with, so ordinal N
        /// here is timing N once that chunk is synthesized. That's what lets
        /// "Play from here" target the tapped *word* on a chunk that hasn't
        /// been synthesized yet, rather than falling back to its start.
        let ordinalInChunk: Int
        let lineBreaksBefore: Int
    }

    private func wordItems(for group: [Int]) -> [FlowWordItem] {
        let texts = visibleChunkTexts
        var items: [FlowWordItem] = []
        for (positionInGroup, chunkIndex) in group.enumerated() {
            guard texts.indices.contains(chunkIndex) else { continue }
            // Newlines at the END of the previous chunk's text would
            // otherwise be lost entirely: splitPreservingSeparators only
            // reports whitespace that *precedes* a word, so a chunk ending
            // in "\n\n" has nothing to attach them to. Carry them onto this
            // chunk's first word instead. (A break mid-chunk needs none of
            // this — it's already some word's own precedingSeparator.)
            let carriedBreaks =
                positionInGroup == 0
                ? 0 : trailingNewlineCount(of: texts[group[positionInGroup - 1]])
            let timings = isCurrentKokoroPageActive
                ? chapterPlayer.wordTimings(forChunk: chunkIndex) : []
            let tokens: [(word: String, precedingSeparator: String, wordIndexInChunk: Int?)]
            if timings.isEmpty {
                tokens = WordTimingDeriver.splitPreservingSeparators(texts[chunkIndex])
                    .map { ($0.word, $0.precedingSeparator, nil) }
            } else {
                tokens = timings.enumerated().map { ($1.word, $1.precedingSeparator, $0) }
            }
            for (i, token) in tokens.enumerated() {
                // `\.isNewline`, not `== "\n"`: Swift treats CRLF as a single
                // Character that is not equal to "\n", so pasted Windows text
                // rendered no breaks at all — and `computeChunkGaps` already
                // uses `isNewline`, so the two halves disagreed.
                let ownBreaks = token.precedingSeparator.filter(\.isNewline).count
                let breaks: Int
                if i > 0 {
                    breaks = ownBreaks
                } else if positionInGroup == 0 {
                    // The group's very first word — nothing to break from.
                    breaks = 0
                } else {
                    breaks = max(carriedBreaks, ownBreaks)
                }
                items.append(
                    FlowWordItem(
                        text: token.word, chunkIndex: chunkIndex,
                        wordIndexInChunk: token.wordIndexInChunk,
                        ordinalInChunk: i,
                        lineBreaksBefore: min(2, breaks)))
            }
        }
        return items
    }

    private func trailingNewlineCount(of text: String) -> Int {
        var count = 0
        for character in text.reversed() {
            if character.isNewline {
                count += 1
            } else if character.isWhitespace {
                continue
            } else {
                break
            }
        }
        return count
    }

    /// A tap on a word selects it (showing "Play from here") rather than
    /// seeking immediately — a mis-tap while reading must not jump
    /// playback. Tapping the same word again deselects it. Deliberately
    /// works on an idle page too (no `isCurrentKokoroPageActive` guard,
    /// unlike the old paragraph-tap-to-seek this replaced): `playFromWord`
    /// starts playback itself when nothing is active yet.
    private func handleWordTap(groupIndex: Int, itemIndex: Int) {
        let target = SelectedWordTarget(groupIndex: groupIndex, itemIndex: itemIndex)
        selectedWordTarget = selectedWordTarget == target ? nil : target
    }

    private func handleConfirmPlay(groupIndex: Int, itemIndex: Int) {
        selectedWordTarget = nil
        guard let page = currentPage else { return }
        let group = effectiveGroups.indices.contains(groupIndex) ? effectiveGroups[groupIndex] : []
        let items =
            paragraphWordItems.indices.contains(groupIndex)
            ? paragraphWordItems[groupIndex] : wordItems(for: group)
        guard items.indices.contains(itemIndex) else { return }
        let item = items[itemIndex]
        chapterPlayer.playFromWord(
            ref: pageRef, page: page,
            chunkIndex: item.chunkIndex, wordIndex: item.ordinalInChunk,
            voice: selectedVoiceName, bookTitle: project.title)
    }
}
