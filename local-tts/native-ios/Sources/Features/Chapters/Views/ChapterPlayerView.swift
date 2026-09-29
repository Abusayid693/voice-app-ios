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

/// The page reader: one persisted page is visible at a time beneath a
/// progressive-blur reading header, with a themed audiobook transport floating over
/// the bottom. The transport combines elapsed/total time,
/// page selection/navigation, voice selection and playback controls; text
/// keeps scrolling underneath it rather than reserving a card-sized inset.
/// Opens at the project's saved page position (or page 1 when unavailable).
/// Playback is always synthesize-and-play (`player.stream`) — there
/// is no persisted "Generate" audio anymore (removed, see CHANGELOG), so
/// this view never asks which mode is active. `duration` is an *estimate*
/// of the current page's full length rather than a running sum of retained
/// audio (bounded lookahead means that sum would freeze at ~2 chunks'
/// worth), and seeking anywhere triggers on-demand synthesis rather than
/// being clamped — both handled inside `BookAudioPlayer`.
///
/// With continuous playback on, the player can advance to the next
/// page on its own mid-session (prefetching across the boundary), which
/// this view observes via `player.activeRef` rather than driving —
/// see the `.onChange(of: player.activeRef)` handler, which updates
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
    @ObservedObject var player: BookAudioPlayer
    @ObservedObject var viewModel: TTSViewModel

    @Environment(\.dismiss) private var dismiss

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
    // Precomputed per-group word items (see wordItems(for:)) + a
    // per-group revision, both feeding ParagraphRow's Equatable
    // conformance — the actual fix for read-along scroll jank. Without
    // this, every group's words were rebuilt from scratch on every 4Hz
    // publish from chapterPlayer's ticker, whether or not that group's
    // content changed. Recomputed on appear and whenever a new chunk's
    // words become available (streaming — see the player.duration
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
    // while nothing is playable yet (player.isBuffering — true
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
    /// Which of the three surfaces this screen is showing. All three are
    /// branches of one view over one player, so switching is a view change
    /// and never touches playback — see `readingSurface`.
    @AppStorage("chapterPlayerSurfaceMode") private var surfaceMode: ReaderSurfaceMode = .text
    /// Set by a push that wants a specific surface regardless of the stored
    /// preference — the mini player opens straight into `.audio`. Applied
    /// once on appear.
    private let initialSurfaceMode: ReaderSurfaceMode?
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
        initialSurfaceMode: ReaderSurfaceMode? = nil,
        library: LibraryViewModel,
        player: BookAudioPlayer,
        viewModel: TTSViewModel,
        previewPlayer: VoicePreviewPlayer,
        readingStats: ReadingStatsStore
    ) {
        self.project = project
        self.initialSurfaceMode = initialSurfaceMode
        self.library = library
        self.previewPlayer = previewPlayer
        self.readingStats = readingStats
        _player = ObservedObject(wrappedValue: player)
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
        player.isActive(pageRef)
    }

    private var visibleChunkTexts: [String] {
        isCurrentKokoroPageActive && !player.chunkTexts.isEmpty
            ? player.chunkTexts : idleChunkTexts
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

    /// The three presentations of one playback session. Deliberately
    /// branches of a single view rather than separate screens: switching
    /// re-renders a branch, so it cannot re-run `.onAppear` and cannot
    /// disturb the player — the audio keeps going, at the same position,
    /// through every toggle.
    @ViewBuilder
    private var readingSurface: some View {
        switch surfaceMode {
        case .audio:
            NowPlayingSurface(
                player: player,
                coverURL: SavedGeneration.existingCoverURL(id: project.id),
                title: project.title,
                pageIndex: currentPageIndex,
                pageCount: project.pageCount,
                isActive: isCurrentKokoroPageActive,
                topContentInset: 68,
                onTogglePlayPause: toggleKokoroPlayback,
                onSelectPage: changeAudioPage)
        case .originalPage:
            if let sourcePDFURL {
                ReaderPDFPageView(
                    pdfURL: sourcePDFURL, pageIndex: currentPageIndex,
                    highlights: currentChunkPageRects, theme: readerTheme)
                    .padding(.horizontal, 12)
                    .padding(.top, 68)
                    .padding(.bottom, showFloatingPlayer ? 174 : 12)
            } else {
                readAlong
            }
        case .text:
            readAlong
        }
    }

    /// The audio surface carries its own transport and page readout, so the
    /// reader's floating pill and bottom page bar would only duplicate it.
    private var showsReaderChrome: Bool { surfaceMode != .audio }

    var body: some View {
        readingSurface
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsReaderChrome, (!showFloatingPlayer || !hasReadableText) {
                    pageNavigator
                }
            }
            .background(readerTheme.background.ignoresSafeArea())
            // `.overlay`, not a shared ZStack with readAlong: `.safeAreaInset`
            // content composites on top of its own main view, so a ZStack
            // sibling of readAlong still painted *under* pageNavigator's
            // background wherever the pill's negative bottom padding dipped
            // into that region. An overlay applied after the inset is
            // guaranteed to draw on top of both.
            .overlay(alignment: .bottom) {
                if showsReaderChrome, showFloatingPlayer, hasReadableText {
                    floatingPlayer
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .offset(y: 26)
                }
            }
            .overlay(alignment: .top) {
                if surfaceMode != .audio {
                    readerHeaderBackdrop
                        .ignoresSafeArea(edges: .top)
                }
            }
            .overlay(alignment: .top) {
                readerHeader
            }
        .toolbar(.hidden, for: .navigationBar)
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
        .preferredColorScheme(surfaceMode == .audio ? .dark : readerTheme.colorScheme)
        .onChange(of: keepScreenOn) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: autoScrollEnabled) { _, isEnabled in
            if !isEnabled {
                isAutoScrollPaused = false
            }
        }
        // Bumped once per chunk landing (see BookAudioPlayer.synthesisRevision),
        // which is exactly when a paragraph's words need to upgrade from the
        // plain-text fallback to real word timings. Not a per-frame cost.
        // `duration` alone isn't reliable for this now that it's an estimate
        // that can occasionally recompute to the same value between two
        // arrivals — see that property's own doc comment.
        .onChange(of: player.synthesisRevision) { _, _ in
            if isCurrentKokoroPageActive { recomputeWordItems() }
        }
        // Grouping was computed only in .onAppear, so entering the player
        // before the chunker had run (chunkTexts still empty) left the whole
        // session on the per-chunk fallback, never grouped into paragraphs.
        .onChange(of: player.chunkTexts.count) { _, _ in
            if isCurrentKokoroPageActive {
                paragraphGroups = computeParagraphGroups()
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
        .onChange(of: player.activeRef) { _, newRef in
            guard let newRef, newRef.projectID == project.id, newRef.pageIndex != currentPageIndex
            else { return }
            isProgrammaticPageChange = true
            pageNumberTransitionDirection = .forward
            currentPageIndex = newRef.pageIndex
            _ = loadPage(newRef.pageIndex)
            // No `recordLastReadPage` here: the player writes the position
            // itself on every promotion (via `positionWriter`), because it
            // advances whether or not this screen is on-screen to see it.
            // Only *user-driven* page changes are this view's to persist.
        }
        // The player doesn't get a new @Published "just completed"
        // signal (would re-render every visible ParagraphRow on every
        // change) — reacting to isPlaying turning false already covers
        // every real stop, natural finish included, at no extra publish
        // cost.
        .onChange(of: player.isPlaying) { _, isPlaying in
            if !isPlaying { refreshCompletedPages() }
        }
        .onChange(of: continuousPlaybackEnabled) { _, newValue in
            player.setContinuousPlaybackEnabled(newValue)
        }
        .onAppear {
            if let initialSurfaceMode { surfaceMode = initialSurfaceMode }
            isAutoScrollPaused = false
            refreshCompletedPages()
            player.configureContinuousPlayback(
                enabled: continuousPlaybackEnabled,
                nextPageProvider: { [library, project] index in
                    library.page(for: project, index: index)
                })
            // Adopt a session already running on this page rather than
            // restarting it: with one shared player, opening the reader on
            // the book that's currently playing (from the mini player, say)
            // must not stop the audio. `moveToPage` tears playback down, so
            // it's only for pages the player isn't already on.
            if player.isActive(pageRef) {
                _ = loadPage(currentPageIndex)
            } else {
                _ = moveToPage(currentPageIndex)
            }
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            // Deliberately does **not** stop playback: leaving the reader
            // hands off to the floating mini player, which is the whole
            // point of it. Playback now ends only on an explicit stop, a
            // different book starting, or the end of this one.
            // Unconditional, not just "if keepScreenOn" — this is a
            // process-global flag, and leaving with the toggle on must not
            // keep the rest of the app from ever auto-locking.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Reader header

    /// A custom header keeps the book title and contextual controls in a
    /// stable layout on every reader surface. It is overlaid rather
    /// than inset so reading content can scroll beneath the progressive
    /// blur; audio mode removes that treatment to expose its artwork.
    private var readerHeader: some View {
        HStack(spacing: 10) {
            readerHeaderButton(label: "Back") {
                dismiss()
            } icon: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
            }

            Text(project.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(headerPrimaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // The page count is an overlay, not part of this title's
                // layout, so the title remains vertically centered in the
                // header while its metadata sits just beneath it.
                .overlay(alignment: .bottomLeading) {
                    animatedPageTitle
                        .offset(y: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            readerSurfaceButton

            readerHeaderButton(label: "Reader options") {
                isOptionsSheetPresented = true
            } icon: {
                LucideIcon(.ellipsis, size: 21, color: headerPrimaryColor)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
    }

    /// Direct surface navigation instead of a menu: Read Along can reveal
    /// the imported PDF, while Original Page and Audio both return to text.
    /// Audio itself is entered from the floating transport below.
    @ViewBuilder
    private var readerSurfaceButton: some View {
        switch surfaceMode {
        case .text:
            if canShowOriginalPage {
                readerHeaderButton(label: "Show original page") {
                    setSurface(.originalPage)
                } icon: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(headerAccentColor)
                }
            }
        case .originalPage, .audio:
            readerHeaderButton(label: "Show read along") {
                setSurface(.text)
            } icon: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(headerAccentColor)
            }
        }
    }

    private func readerHeaderButton<Icon: View>(
        label: String, action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            ZStack {
                headerControlBackground
                icon().foregroundStyle(headerPrimaryColor)
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var readerHeaderBackdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(readerTheme.background.opacity(0.08))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.62),
                        .init(color: .black.opacity(0.35), location: 0.84),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
            .frame(height: 130)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Artwork supplies all Audio Player color, so its controls have no
    /// material, tint, gradient, or blur between their icons and the image.
    @ViewBuilder
    private var headerControlBackground: some View {
        if surfaceMode == .audio {
            Circle().fill(.clear)
        } else {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(readerTheme.controlBackground.opacity(0.54))
        }
    }

    private var headerPrimaryColor: Color {
        surfaceMode == .audio ? .white : readerTheme.primaryText
    }

    private var headerSecondaryColor: Color {
        surfaceMode == .audio ? .white.opacity(0.68) : readerTheme.secondaryText
    }

    private var headerAccentColor: Color {
        surfaceMode == .audio ? .white : readerTheme.controlAccent
    }

    private func setSurface(_ mode: ReaderSurfaceMode) {
        withAnimation(.easeInOut(duration: 0.2)) {
            surfaceMode = mode
        }
    }

    /// Compact navigation fallback used only when the full floating
    /// transport is hidden or the current page has no playable text.
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
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(headerSecondaryColor)
        // Tall enough for the slider's own fade margin, so the nav bar never
        // clips a travelling number back to a hard edge.
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Page \(currentPageIndex + 1) of \(project.pageCount)"
                + (completedPageIndices.contains(currentPageIndex) ? ", completed" : ""))
    }

    private var tickSlotWidth: CGFloat { 13 }

    private var tickSlot: some View {
        LucideIcon(.check, size: 13, color: headerPrimaryColor)
            .frame(width: tickSlotWidth)
            .accessibilityHidden(true)
    }

    private var pageNumberWidth: CGFloat {
        // The subtitle is leading-aligned, so reserving enough width for the
        // book's largest page number leaves a visible blank before short
        // values (for example, "12" in a 200-page book). Keep only the width
        // required by the current monospaced digits.
        max(8, CGFloat(String(currentPageIndex + 1).count) * 7)
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

    private func changeVoice(_ voiceName: String) {
        guard voiceName != selectedVoiceName else { return }

        player.stop()
        isPulsingPlayButton = false

        guard library.updateVoice(voiceName, for: project.id) else {
            isVoiceChangeErrorPresented = true
            return
        }
        selectedVoiceName = voiceName
    }

    @discardableResult
    private func moveToPage(_ index: Int) -> Bool {
        player.stop()
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
        let styling = makePageStyling()
        let fresh = effectiveGroups.map { wordItems(for: $0, styling: styling) }
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
        let index = player.currentChunkIndex
        guard isCurrentKokoroPageActive, texts.indices.contains(index) else { return [] }
        let ranges = chunkRanges(in: page.text, texts: texts)
        guard ranges.indices.contains(index), let range = ranges[index] else { return [] }

        let start = page.text.distance(from: page.text.startIndex, to: range.lowerBound)
        let end = page.text.distance(from: page.text.startIndex, to: range.upperBound)
        return page.lineRects
            .filter { $0.start < end && $0.end > start }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    // MARK: - Floating player

    /// Full-width floating transport modeled after a compact audiobook
    /// controller: page list/time/page-turn controls in the header, and
    /// voice/seek/play controls beneath it.
    /// The page arrows deliberately replace the reference design's close
    /// button—the reader already has a dedicated close control in its header.
    private var floatingPlayer: some View {
        VStack(spacing: 6) {
            ZStack {
                Text("\(Self.formattedPlayerTime(playerElapsed))  /  \(Self.formattedPlayerTime(playerDuration))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(readerTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    playerHeaderButton(
                        systemImage: "list.bullet", label: "Choose page", isEnabled: true
                    ) {
                        refreshCompletedPages()
                        isPagePickerPresented = true
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 2) {
                        playerHeaderButton(
                            systemImage: "chevron.left", label: "Previous page",
                            isEnabled: currentPageIndex > 0
                        ) {
                            selectPage(currentPageIndex - 1)
                        }

                        playerHeaderButton(
                            systemImage: "chevron.right", label: "Next page",
                            isEnabled: currentPageIndex < project.pageCount - 1
                        ) {
                            selectPage(currentPageIndex + 1)
                        }
                    }
                }
            }

            HStack(spacing: 0) {
                voiceButton
                    .frame(maxWidth: .infinity)

                skipButton(icon: .rotateCcw, label: "10") {
                    player.skipBackward(by: 10)
                }
                .frame(maxWidth: .infinity)

                playPauseButton
                    .frame(maxWidth: .infinity)

                skipButton(icon: .rotateCw, label: "10") {
                    player.skipForward(by: 10)
                }
                .frame(maxWidth: .infinity)

                Button {
                    setSurface(.audio)
                } label: {
                    Image(systemName: "headphones")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(readerTheme.primaryText)
                        .frame(width: 52, height: 52)
                        .background(
                            readerTheme.controlBackground,
                            in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Show audio player")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background { playerBackground(cornerRadius: 24) }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .onTapGesture { }
    }

    private func playerHeaderButton(
        systemImage: String, label: String, isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(readerTheme.primaryText)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private var playerElapsed: TimeInterval {
        isCurrentKokoroPageActive ? player.elapsed : 0
    }

    private var playerDuration: TimeInterval {
        isCurrentKokoroPageActive ? player.duration : 0
    }

    private static func formattedPlayerTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
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
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(readerTheme.controlBackground.opacity(0.58))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(readerTheme.primaryText.opacity(0.1), lineWidth: 0.75)
                }
        }
    }

    private var playPauseButton: some View {
        PlayPauseBounceButton(
            isPlaying: isCurrentKokoroPageActive && player.isPlaying,
            tapTargetSize: 70,
            action: toggleKokoroPlayback
        ) { isPlaying in
            ZStack {
                Circle().fill(readerTheme.controlAccent)
                (isPlaying ? Hugeicons.pause : Hugeicons.play)
                    .image()
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(readerTheme.highlightedText)
                    .frame(width: 31, height: 31)
            }
            .frame(width: 68, height: 68)
        }
        // A hard reset (no bounce) whenever the page or voice changes —
        // both already call `player.stop()` first, so `isPlaying`
        // reads false the instant this identity change recreates the
        // button's state. See PlayPauseBounceButton's own doc comment.
        .id("\(currentPageIndex)-\(selectedVoiceName)")
        .accessibilityLabel(isCurrentKokoroPageActive && player.isPlaying ? "Pause" : "Play")
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
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(bufferingRingAngle(at: context.date)))
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            updatePlayButtonPulse(
                isBuffering: isCurrentKokoroPageActive && player.isBuffering)
        }
        .onChange(of: player.isBuffering) { _, isBuffering in
            updatePlayButtonPulse(isBuffering: isCurrentKokoroPageActive && isBuffering)
        }
    }

    /// Next/previous page from the audio surface. Routed through the player
    /// while it's playing this book, so a page change there behaves like a
    /// music player's next-track — it keeps playing, and the reader follows
    /// via its `activeRef` handler. `selectPage` alone would go through
    /// `moveToPage`, which stops playback; that's right for a deliberate
    /// page turn while reading, wrong for a transport button.
    private func changeAudioPage(to index: Int) {
        guard (0..<project.pageCount).contains(index) else { return }
        if isCurrentKokoroPageActive {
            player.jumpToPage(index)
        } else {
            selectPage(index)
        }
    }

    private func toggleKokoroPlayback() {
        guard let page = currentPage, hasReadableText else { return }
        if player.isActive(pageRef) {
            player.togglePlayPause()
        } else {
            player.start(
                project: project, page: page, startIndex: currentPageIndex,
                voice: selectedVoiceName,
                pageProvider: pageProvider, positionWriter: positionWriter)
        }
    }

    /// The player has no `LibraryViewModel`, so it's handed how to load a
    /// page and how to persist the position as it advances. Both capture
    /// `library`/`project` and nothing view-specific, so they stay valid for
    /// the whole session — including after this screen is dismissed and
    /// playback continues under the mini player.
    private var pageProvider: (Int) -> ReaderPage? {
        { [library, project] index in library.page(for: project, index: index) }
    }

    private var positionWriter: (Int) -> Void {
        { [library, project] index in
            library.recordLastReadPage(index: index, for: project.id)
        }
    }

    private var voiceButton: some View {
        Button {
            presentVoiceSelection()
        } label: {
            Image(VoiceCoverArt.assetName(for: selectedVoiceName))
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(readerTheme.primaryText.opacity(0.16), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change voice, currently \(selectedVoiceName)")
    }

    private func presentVoiceSelection() {
        if player.isActive(pageRef), player.isPlaying {
            player.togglePlayPause()
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
            .frame(width: 52, height: 52)
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
                            showFloatingPlayer ? 170 : 0)
                    }
                }
            }
            .contentMargins(.top, 68, for: .scrollContent)
            .id(currentPageIndex)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged(handleReaderDragChanged)
                    .onEnded(handleReaderDragEnded)
            )
            .onChange(of: player.currentChunkIndex) { _, chunkIndex in
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
                        forChunk: player.currentChunkIndex)
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
                                    forChunk: player.currentChunkIndex)
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
            $0.contains(player.currentChunkIndex)
        }) else { return false }
        return !visibleParagraphsBox.indices.contains(groupIndex)
    }

    private var currentSpokenWord: String {
        guard let highlight = player.currentHighlight() else { return "Current" }
        let timings = player.wordTimings(forChunk: highlight.chunkIndex)
        guard timings.indices.contains(highlight.wordIndex) else { return "Current" }
        return timings[highlight.wordIndex].word
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
            ? paragraphWordItems[groupIndex] : wordItems(for: group, styling: makePageStyling())
        let revision = paragraphRevisions.indices.contains(groupIndex) ? paragraphRevisions[groupIndex] : 0
        // Position only — NOT gated on isPlaying, so the chunk band and
        // its last-highlighted word stay put on pause instead of both
        // disappearing. What isPlaying actually decides is below: whether
        // this row needs to keep ticking to track a moving position.
        let isCurrentGroup = isCurrentKokoroPageActive
            && group.contains(player.currentChunkIndex)
        let hasAnyWordTimings = items.contains { $0.wordIndexInChunk != nil }
        let showsWordHighlight = wordHighlightEnabled && hasAnyWordTimings && isCurrentGroup
        let isPolling = showsWordHighlight && player.isPlaying

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
            // One read for both halves — see `currentHighlight()`. Reading the
            // chunk and the word separately let them disagree across a chunk
            // boundary, which flashed the finished chunk's first word.
            let highlight = showsWordHighlight ? player.currentHighlight() : nil
            ParagraphRow(
                items: items, itemsRevision: revision,
                highlightedChunkIndex: highlight?.chunkIndex,
                highlightedWordIndex: highlight?.wordIndex,
                currentChunkIndex: isCurrentGroup ? player.currentChunkIndex : nil,
                isCurrentGroup: isCurrentGroup,
                fontSize: readerFontSize,
                fontFamily: readerFontFamily,
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
                && lhs.theme == rhs.theme
                && lhs.selectedItemIndex == rhs.selectedItemIndex
        }

        // The inputs that can change a word's measured size. Colors (which is
        // all the highlight changes) can't, so the ~12x/sec re-runs while this
        // paragraph plays reuse the measured sizes instead of re-measuring
        // every word each time. Per-word styles ride in on `itemsRevision`:
        // `FlowWordItem` compares its own style, so a style change is already a
        // content change that bumps the revision.
        private var measurementVersion: Int {
            var hasher = Hasher()
            hasher.combine(itemsRevision)
            hasher.combine(fontSize)
            hasher.combine(fontFamily)
            return hasher.finalize()
        }

        private func font(for style: ReaderTextStyle?) -> Font {
            guard let style else { return fontSize.font(family: fontFamily) }
            return fontSize.font(family: fontFamily, style: style)
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
                        .font(font(for: item.style))
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
            // Emphasised body text is styled but is *not* a section opener, so
            // it takes the document's weight without the space above. Read off
            // the first word, since that is what decides whether this row opens
            // a section — a heading mid-row is preceded by its own line break.
            .padding(.top, items.first?.style.map { $0.isHeading ? ($0.scale - 1) * 20 + 10 : 0 } ?? 0)
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
        /// The document's own treatment for this word, resolved from its
        /// character offset in the page text.
        ///
        /// Per *word* rather than per row because a row is a paragraph group,
        /// and the synthesis chunker does not respect headings: "Communalist
        /// Approach" and the 300 characters of body text after it land in one
        /// chunk, so one style for the whole row can only be right for one of
        /// them. Styling by offset also picks up emphasis inside a sentence,
        /// which a row-level style could never express.
        let style: ReaderTextStyle?
    }

    /// Resolves a word's character offset in the page text to whatever style the
    /// document gave it.
    ///
    /// Built once per recompute and handed down: locating chunks inside the page
    /// text is a scan of the whole page, far too expensive to repeat per
    /// paragraph.
    private struct PageStyling {
        let chunkStarts: [Int?]
        let ranges: [ReaderStyledRange]

        var isEmpty: Bool { ranges.isEmpty }

        func chunkStart(_ index: Int) -> Int? {
            chunkStarts.indices.contains(index) ? chunkStarts[index] : nil
        }

        func style(at offset: Int) -> ReaderTextStyle? {
            ranges.first { offset >= $0.start && offset < $0.end }?.style
        }
    }

    private func makePageStyling() -> PageStyling {
        guard let page = currentPage, !page.styledRanges.isEmpty else {
            return PageStyling(chunkStarts: [], ranges: [])
        }
        let starts = chunkRanges(in: page.text, texts: visibleChunkTexts).map { range in
            range.map { page.text.distance(from: page.text.startIndex, to: $0.lowerBound) }
        }
        return PageStyling(chunkStarts: starts, ranges: page.styledRanges)
    }

    private func wordItems(for group: [Int], styling: PageStyling) -> [FlowWordItem] {
        let texts = visibleChunkTexts
        var items: [FlowWordItem] = []
        for (positionInGroup, chunkIndex) in group.enumerated() {
            guard texts.indices.contains(chunkIndex) else { continue }
            // Offsets come from the chunk's own text rather than from whichever
            // token source renders below, so they stay correct even if real
            // timings ever split a word differently from the plain splitter.
            let styleOffsets = styling.isEmpty
                ? [] : wordOffsets(inChunk: texts[chunkIndex], start: styling.chunkStart(chunkIndex))
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
                ? player.wordTimings(forChunk: chunkIndex) : []
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
                        lineBreaksBefore: min(2, breaks),
                        style: styleOffsets.indices.contains(i)
                            ? styling.style(at: styleOffsets[i]) : nil))
            }
        }
        return items
    }

    /// Each word's character offset within the page text, walked from the
    /// chunk's own start. Character counts throughout, matching
    /// `ReaderStyledRange`'s own offsets.
    private func wordOffsets(inChunk text: String, start: Int?) -> [Int] {
        guard let start else { return [] }
        var offsets: [Int] = []
        var cursor = start
        for token in WordTimingDeriver.splitPreservingSeparators(text) {
            cursor += token.precedingSeparator.count
            offsets.append(cursor)
            cursor += token.word.count
        }
        return offsets
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
            ? paragraphWordItems[groupIndex] : wordItems(for: group, styling: makePageStyling())
        guard items.indices.contains(itemIndex) else { return }
        let item = items[itemIndex]
        player.playFromWord(
            project: project, page: page, pageIndex: currentPageIndex,
            voice: selectedVoiceName,
            chunkIndex: item.chunkIndex, wordIndex: item.ordinalInChunk,
            pageProvider: pageProvider, positionWriter: positionWriter)
    }
}
