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

/// The page reader: one persisted page is visible at a time, with the
/// read-along transport floating above Previous/Next page navigation.
/// text, with a compact, translucent transport bar floating over its
/// bottom (elapsed/total time on top, avatar + −10s/play-pause/+10s
/// below) — text keeps scrolling underneath it, it doesn't reserve its own
/// space.
/// Opens at the project's saved page position (or page 1 when unavailable)
/// and supports both saved playback (`playSaved`) and unsaved streaming (`stream`) — the
/// two feed identical playback/highlighting behavior through
/// `ChapterAudioPlayer`'s shared published surface (`duration`/`elapsed`/
/// `wordTimings(forChunk:)`/etc.), which is kept correct for both modes
/// internally; this view doesn't know or care which one is active. The one
/// real difference during streaming: `duration` grows as chunks arrive
/// rather than being known upfront, and seeking is clamped to what's
/// already been synthesized — both handled inside `ChapterAudioPlayer`.
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
    let voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var chapterPlayer: ChapterAudioPlayer
    @ObservedObject var generationStore: ChapterGenerationStore
    @ObservedObject var viewModel: TTSViewModel

    @State private var currentPageIndex: Int
    @State private var currentPage: ReaderPage?
    @State private var idleChunkTexts: [String] = []

    @State private var isAutoScrollPaused = false
    // Reference type, not @State, for the same reason as groupHeightsBox
    // below: rows cross the scroll-visibility threshold constantly during
    // a flick, and as @State every one of those crossings re-evaluated
    // this whole view — the entire ForEach over every paragraph — on top
    // of the 4Hz ticker and the 12.5Hz highlight poll already running.
    // That made scrolling-while-highlighting janky. Its only consumer is
    // the "jump to current word" pill, which polls (see readAlong's
    // overlay) rather than needing a publish.
    private final class VisibleParagraphsBox {
        var indices: Set<Int> = []
    }
    @State private var visibleParagraphsBox = VisibleParagraphsBox()
    // Fixed once, so the TimelineViews below get a stable schedule value
    // instead of a fresh one built from `.now` on every body pass.
    @State private var pollAnchor = Date()
    @State private var isPlayerCollapsed = false
    @State private var displayedIsPlaying = false
    @State private var playPauseScale: CGFloat = 1
    @State private var playPauseAnimationTask: Task<Void, Never>?
    @Namespace private var floatingPlayerNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    // Reference type, not @State — the tap-position-estimate height
    // measurement in readAlong's GeometryReader fires on layout, not on a
    // meaningful content change, so writing it must not invalidate the
    // view either; these measurements are bookkeeping, not visible state.
    private final class GroupHeightsBox {
        var heights: [Int: CGFloat] = [:]
    }
    @State private var groupHeightsBox = GroupHeightsBox()
    // Play/pause button pulses opacity while nothing is playable yet
    // (chapterPlayer.isBuffering — true entering the player before
    // streaming's first chunk lands, or between chunks if playback ever
    // catches up to the synthesis frontier).
    @State private var isPulsingPlayButton = false
    @State private var isOptionsSheetPresented = false
    @State private var isPagePickerPresented = false
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

    init(
        project: SavedGeneration, initialPageIndex: Int? = nil,
        library: LibraryViewModel, voiceCloneViewModel: VoiceCloneViewModel,
        chapterPlayer: ChapterAudioPlayer,
        generationStore: ChapterGenerationStore, viewModel: TTSViewModel
    ) {
        self.project = project
        self.library = library
        self.voiceCloneViewModel = voiceCloneViewModel
        _chapterPlayer = ObservedObject(wrappedValue: chapterPlayer)
        _generationStore = ObservedObject(wrappedValue: generationStore)
        _viewModel = ObservedObject(wrappedValue: viewModel)
        let requestedIndex = initialPageIndex ?? project.lastReadPageIndex
        let hasValidRequestedIndex = project.pageCount > 0
            && (0..<project.pageCount).contains(requestedIndex)
        let boundedIndex = hasValidRequestedIndex ? requestedIndex : 0
        _currentPageIndex = State(initialValue: boundedIndex)
    }

    private var pageRef: ReaderPageRef {
        ReaderPageRef(projectID: project.id, pageIndex: currentPageIndex)
    }

    private var hasReadableText: Bool {
        !(currentPage?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var isCurrentKokoroPageActive: Bool {
        project.engine == .kokoroAne && chapterPlayer.isActive(pageRef)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            readAlong
            if showFloatingPlayer, hasReadableText {
                // Expanded is 15pt lower than the prior placement; the
                // compact pill sits another 15pt lower (30pt total) while
                // remaining clear of the page-navigation bar.
                floatingPlayer.padding(.bottom, isPlayerCollapsed ? 3 : 18)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { pageNavigator }
        .background(readerTheme.background.ignoresSafeArea())
        .navigationTitle("Page \(currentPageIndex + 1) of \(project.pageCount)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if project.engine == .kokoroAne {
                    generationToolbarControl
                }
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
                fontSize: $readerFontSize,
                fontFamily: $readerFontFamily,
                theme: $readerTheme)
        }
        .sheet(isPresented: $isPagePickerPresented) {
            ReaderPagePickerSheet(
                project: project, library: library, currentPageIndex: currentPageIndex,
                theme: readerTheme,
                onSelect: { currentPageIndex = $0 })
        }
        .preferredColorScheme(readerTheme.colorScheme)
        .onChange(of: keepScreenOn) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: chapterPlayer.isPlaying) { _, isPlaying in
            animatePlayPauseIcon(to: isCurrentKokoroPageActive && isPlaying)
        }
        .onChange(of: autoScrollEnabled) { _, isEnabled in
            if !isEnabled {
                isAutoScrollPaused = false
            }
        }
        // Fires once per chunk as streaming synthesizes it (duration only
        // grows in that mode — see ChapterAudioPlayer.stream), which is
        // exactly when a paragraph's words need to upgrade from the plain-
        // text fallback to real word timings. Not a per-frame cost.
        .onChange(of: chapterPlayer.duration) { _, _ in
            if isCurrentKokoroPageActive { recomputeWordItems() }
        }
        // Grouping was computed only in .onAppear, so entering the player
        // before the chunker had run (chunkTexts still empty) left the whole
        // session on the per-chunk fallback, never grouped into paragraphs.
        .onChange(of: chapterPlayer.chunkTexts.count) { _, _ in
            if isCurrentKokoroPageActive {
                paragraphGroups = computeParagraphGroups()
                recomputeWordItems()
            }
        }
        .onChange(of: currentPageIndex) { oldValue, newValue in
            guard oldValue != newValue else { return }
            guard moveToPage(newValue) else {
                currentPageIndex = oldValue
                return
            }
            library.recordLastReadPage(index: newValue, for: project.id)
        }
        .onAppear {
            isAutoScrollPaused = false
            isPlayerCollapsed = false
            displayedIsPlaying = false
            playPauseScale = 1
            _ = moveToPage(currentPageIndex)
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            playPauseAnimationTask?.cancel()
            chapterPlayer.stop()
            viewModel.stopEnginePlayback()
            // Unconditional, not just "if keepScreenOn" — this is a
            // process-global flag, and leaving with the toggle on must not
            // keep the rest of the app from ever auto-locking.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var pageNavigator: some View {
        HStack(spacing: 12) {
            Button {
                isPagePickerPresented = true
            } label: {
                Label("Pages", systemImage: "list.bullet")
                    .font(AppTextStyle.label.font)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.primaryText)
            .accessibilityLabel("Choose page")

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    currentPageIndex -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            readerTheme.controlBackground,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(readerTheme.primaryText)
                .disabled(currentPageIndex == 0)
                .opacity(currentPageIndex == 0 ? 0.35 : 1)
                .accessibilityLabel("Previous page")

                Button {
                    currentPageIndex += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            readerTheme.controlBackground,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(readerTheme.primaryText)
                .disabled(currentPageIndex >= project.pageCount - 1)
                .opacity(currentPageIndex >= project.pageCount - 1 ? 0.35 : 1)
                .accessibilityLabel("Next page")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72), .black],
                        startPoint: .top,
                        endPoint: .bottom)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var generationToolbarControl: some View {
        if let page = currentPage, hasReadableText {
            switch generationStore.state(for: pageRef) {
            case .queued:
                Button { generationStore.cancel(pageRef) } label: {
                    ProgressView().tint(readerTheme.primaryText)
                }
                .accessibilityLabel("Cancel page generation")
            case let .running(done, total):
                Button { generationStore.cancel(pageRef) } label: {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(readerTheme.primaryText)
                        .frame(width: 24)
                }
                .accessibilityLabel("Cancel page generation, \(done) of \(total) parts complete")
            case .failed:
                Button("Retry") { generate(page) }
                    .font(AppTextStyle.label.font)
            case nil:
                if PageAudioStore.isGenerated(pageRef, project: project) {
                    LucideIcon(.circleCheck, size: 20, color: readerTheme.primaryText)
                        .accessibilityLabel("Page audio generated")
                } else {
                    Button("Generate") { generate(page) }
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(readerTheme.primaryText)
                }
            }
        }
    }

    private func generate(_ page: ReaderPage) {
        generationStore.generate(
            ref: pageRef, project: project, page: page, voice: project.voiceName)
    }

    @discardableResult
    private func moveToPage(_ index: Int) -> Bool {
        guard let page = library.page(for: project, index: index) else { return false }
        chapterPlayer.stop()
        viewModel.stopEnginePlayback()
        playPauseAnimationTask?.cancel()
        displayedIsPlaying = false
        playPauseScale = 1
        isPulsingPlayButton = false
        isAutoScrollPaused = false
        visibleParagraphsBox = VisibleParagraphsBox()
        groupHeightsBox = GroupHeightsBox()

        currentPage = page
        idleChunkTexts = KokoroTextChunker.chunk(page.text)
        paragraphGroups = computeParagraphGroups()
        paragraphWordItems = []
        paragraphRevisions = []
        recomputeWordItems()
        return true
    }

    // Starting a `.repeatForever` animation from `false` toggles it into
    // an indefinite back-and-forth between 1 and 0.5 opacity; setting it
    // back to `false` (with its own short, non-repeating animation) is
    // what stops it once something is actually playable.
    private func updatePlayButtonPulse(isBuffering: Bool) {
        if isBuffering {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isPulsingPlayButton = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPulsingPlayButton = false
            }
        }
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
        var searchStart = fullText.startIndex
        var previousEnd: String.Index?
        for (index, text) in texts.enumerated() {
            guard let range = fullText.range(of: text, range: searchStart..<fullText.endIndex) else {
                // Couldn't locate this chunk verbatim (shouldn't happen —
                // fail safe to a normal gap rather than guessing).
                previousEnd = nil
                continue
            }
            if index > 0, let previousEnd {
                // Three places the break can be, not one. `KokoroTextChunker`
                // trims chunks with `.whitespaces`, which excludes newlines
                // (CharacterSet.whitespaces is Unicode Zs + tab), so a
                // paragraph's newline usually rides along *inside* a chunk's
                // own text — and since chunk ranges are contiguous, the gap
                // between two matches is then empty. Checking only the gap
                // reported "no break" at every boundary, merging a whole
                // chapter into one paragraph group.
                gaps[index] =
                    fullText[previousEnd..<range.lowerBound].contains(where: \.isNewline)
                    || texts[index - 1].last?.isNewline == true
                    || text.first?.isNewline == true
            }
            previousEnd = range.upperBound
            searchStart = range.upperBound
        }
        return gaps
    }

    // MARK: - Floating player

    @ViewBuilder
    private var floatingPlayer: some View {
        if project.engine == .kokoroAne {
            ZStack(alignment: .bottom) {
                if isPlayerCollapsed {
                    compactPlayer
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                } else {
                    expandedPlayer
                        .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .offset(y: 25)
        } else {
            nonKokoroPlayer
        }
    }

    private var expandedPlayer: some View {
        // 56pt header + 64pt transport row - 4pt overlap = 116pt,
        // approximately 70% of the previous 166pt card, without shrinking
        // any of the enlarged control hit targets.
        VStack(spacing: -4) {
            durationHeader
            transportRow
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background { playerBackground(cornerRadius: 20) }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { }
    }

    private var durationHeader: some View {
        ZStack(alignment: .trailing) {
            Text("\(Self.formatTime(chapterPlayer.elapsed)) | \(Self.formatTime(chapterPlayer.duration))")
                .appText(.meta)
                .foregroundStyle(readerTheme.secondaryText)
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    isPlayerCollapsed = true
                }
            } label: {
                LucideIcon(.x, size: 20, color: readerTheme.primaryText)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse player")
        }
        .frame(height: 56)
    }

    private var compactPlayer: some View {
        HStack(spacing: 4) {
            playPauseButton

            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    isPlayerCollapsed = false
                }
            } label: {
                LucideIcon(.chevronUp, size: 24, color: readerTheme.primaryText)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand player")
        }
        .background { playerBackground(cornerRadius: 32) }
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onTapGesture { }
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
                .matchedGeometryEffect(id: "playerBackground", in: floatingPlayerNamespace)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(readerTheme.controlBackground)
                .matchedGeometryEffect(id: "playerBackground", in: floatingPlayerNamespace)
        }
    }

    private var transportRow: some View {
        HStack {
            avatar

            Spacer()

            HStack(spacing: 28) {
                skipButton(icon: .rotateCcw, label: "10") {
                    chapterPlayer.skipBackward()
                }

                playPauseButton

                skipButton(icon: .rotateCw, label: "10") {
                    chapterPlayer.skipForward()
                }
            }

            Spacer()

            // Balances the avatar's width so the transport controls above
            // stay visually centered in the bar rather than skewed toward
            // the trailing edge.
            Color.clear.frame(width: 44, height: 1)
        }
    }

    private var playPauseButton: some View {
        Button {
            toggleKokoroPlayback()
        } label: {
            (displayedIsPlaying ? Hugeicons.pause : Hugeicons.play)
                .image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(readerTheme.primaryText)
                .contentTransition(.identity)
                .frame(width: 44, height: 44)
                .scaleEffect(playPauseScale)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrentKokoroPageActive && chapterPlayer.isPlaying ? "Pause" : "Play")
        .disabled(!hasReadableText)
        .opacity(isPulsingPlayButton ? 0.5 : 1)
        .onAppear {
            updatePlayButtonPulse(
                isBuffering: isCurrentKokoroPageActive && chapterPlayer.isBuffering)
        }
        .onChange(of: chapterPlayer.isBuffering) { _, isBuffering in
            updatePlayButtonPulse(isBuffering: isCurrentKokoroPageActive && isBuffering)
        }
        .matchedGeometryEffect(id: "playPauseButton", in: floatingPlayerNamespace)
    }

    private var nonKokoroPlayer: some View {
        HStack(spacing: 14) {
            avatar
            Text(project.engine.rawValue)
                .appText(.label)
                .foregroundStyle(readerTheme.primaryText)
            Spacer()
            Button {
                toggleNonKokoroPlayback()
            } label: {
                Image(systemName: viewModel.isReaderPlaybackActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(readerTheme.primaryText)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isReaderPlaybackActive ? "Stop" : "Play")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background { playerBackground(cornerRadius: 20) }
        .padding(.horizontal)
        .offset(y: 17)
    }

    private func toggleKokoroPlayback() {
        guard let page = currentPage, hasReadableText else { return }
        viewModel.stopEnginePlayback()
        if chapterPlayer.isActive(pageRef) {
            chapterPlayer.togglePlayPause()
        } else if PageAudioStore.isGenerated(pageRef, project: project) {
            chapterPlayer.playSaved(pageRef, project: project)
        } else {
            chapterPlayer.stream(pageRef, page: page, voice: project.voiceName)
        }
    }

    private func toggleNonKokoroPlayback() {
        guard let page = currentPage, hasReadableText else { return }
        chapterPlayer.stop()
        if viewModel.isReaderPlaybackActive {
            viewModel.stopEnginePlayback()
        } else {
            viewModel.speakPage(
                text: page.text, engine: project.engine, voiceName: project.voiceName,
                clonedVoice: voiceCloneViewModel.clonedVoices.first { $0.name == project.voiceName })
        }
    }

    private func animatePlayPauseIcon(to isPlaying: Bool) {
        playPauseAnimationTask?.cancel()

        guard !reduceMotion else {
            displayedIsPlaying = isPlaying
            playPauseScale = 1
            return
        }

        withAnimation(.easeIn(duration: 0.09)) {
            playPauseScale = 0.76
        }

        playPauseAnimationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }

            // Swap without animation at the compressed midpoint so the two
            // PDF assets never cross-fade through one another.
            displayedIsPlaying = isPlaying
            withAnimation(.spring(response: 0.32, dampingFraction: 0.52)) {
                playPauseScale = 1
            }
        }
    }

    private var avatar: some View {
        Image(VoiceCoverArt.assetName(for: project.voiceName))
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(Circle())
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

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Read-along text

    private var readAlong: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                            let group = effectiveGroups[groupIndex]
                            paragraphRowView(groupIndex: groupIndex)
                                .id(groupIndex)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .onAppear { groupHeightsBox.heights[groupIndex] = geo.size.height }
                                            .onChange(of: geo.size.height) { _, newValue in
                                                groupHeightsBox.heights[groupIndex] = newValue
                                            }
                                    }
                                )
                                .gesture(
                                    SpatialTapGesture().onEnded { value in
                                        handleParagraphTap(
                                            group: group, groupIndex: groupIndex,
                                            localY: value.location.y)
                                    }
                                )
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
                    .padding()
                    .padding(
                        .bottom,
                        showFloatingPlayer ? (isPlayerCollapsed ? 48 : 100) : 0)
                }
            }
            .id(currentPageIndex)
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    guard isCurrentKokoroPageActive, autoScrollEnabled, !isAutoScrollPaused else { return }
                    isAutoScrollPaused = true
                }
            )
            .onChange(of: chapterPlayer.currentChunkIndex) { _, chunkIndex in
                guard isCurrentKokoroPageActive, autoScrollEnabled, !isAutoScrollPaused else { return }
                guard let (groupIndex, anchor) = scrollTarget(forChunk: chunkIndex) else { return }
                withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
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
        // Position only — NOT gated on isPlaying, so the paragraph box and
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
        return TimelineView(.periodic(from: pollAnchor, by: isPolling ? 0.08 : 3600)) { _ in
            ParagraphRow(
                items: items, itemsRevision: revision,
                highlightedChunkIndex: showsWordHighlight ? chapterPlayer.currentChunkIndex : nil,
                highlightedWordIndex: showsWordHighlight
                    ? chapterPlayer.currentWordIndex(atElapsed: chapterPlayer.currentPlaybackTime) : nil,
                isCurrentGroup: isCurrentGroup,
                fontSize: readerFontSize,
                fontFamily: readerFontFamily,
                theme: readerTheme
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
    // full opacity; only the word background and the paragraph box signal
    // position. Every word carries constant padding regardless of
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
        let isCurrentGroup: Bool
        let fontSize: ReaderFontSize
        let fontFamily: ReaderFontFamily
        let theme: ReaderTheme

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.itemsRevision == rhs.itemsRevision && lhs.highlightedChunkIndex == rhs.highlightedChunkIndex
                && lhs.highlightedWordIndex == rhs.highlightedWordIndex && lhs.isCurrentGroup == rhs.isCurrentGroup
                && lhs.fontSize == rhs.fontSize && lhs.fontFamily == rhs.fontFamily && lhs.theme == rhs.theme
        }

        // The two inputs that can change a word's measured size. Colors
        // (which is all the highlight changes) can't, so the ~12x/sec
        // re-runs while this paragraph plays reuse the measured sizes
        // instead of re-measuring every word each time.
        private var measurementVersion: Int {
            var hasher = Hasher()
            hasher.combine(itemsRevision)
            hasher.combine(fontSize)
            hasher.combine(fontFamily)
            return hasher.finalize()
        }

        var body: some View {
            WordFlowLayout(
                horizontalSpacing: 2, verticalSpacing: 2, paragraphExtraSpacing: 6,
                measurementVersion: measurementVersion
            ) {
                // items.indices, not Array(items.enumerated()) — the
                // latter allocates a fresh tuple array on every body run,
                // which for the playing paragraph is 12x/sec.
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    let isHighlighted =
                        isCurrentGroup && item.chunkIndex == highlightedChunkIndex
                            && item.wordIndexInChunk == highlightedWordIndex
                    Text(item.text)
                        .font(fontSize.font(family: fontFamily))
                        .foregroundStyle(isHighlighted ? theme.highlightedText : theme.primaryText)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(
                            isHighlighted ? theme.wordHighlightBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                        .lineBreaksBefore(item.lineBreaksBefore)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(
                isCurrentGroup ? theme.chunkHighlightBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
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
                let ownBreaks = token.precedingSeparator.filter { $0 == "\n" }.count
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
                        lineBreaksBefore: min(2, breaks)))
            }
        }
        return items
    }

    private func trailingNewlineCount(of text: String) -> Int {
        var count = 0
        for character in text.reversed() {
            if character == "\n" {
                count += 1
            } else if character.isWhitespace {
                continue
            } else {
                break
            }
        }
        return count
    }

    private func handleParagraphTap(group: [Int], groupIndex: Int, localY: CGFloat) {
        guard isCurrentKokoroPageActive else { return }
        let target: Int
        if group.count > 1 {
            let height = groupHeightsBox.heights[groupIndex] ?? 0
            let proportion = height > 0 ? Double(max(0, min(localY, height)) / height) : 0
            target = estimatedChunk(inGroup: group, atProportion: proportion)
        } else {
            target = group[0]
        }
        guard let start = chapterPlayer.startTime(forChunk: target) else { return }
        chapterPlayer.seek(to: start)
    }

    // Maps a vertical tap position (0...1 down the paragraph) to a chunk
    // index, weighted by each chunk's character length — an estimate, not
    // exact (assumes fairly even text density), but far more useful on a
    // couple-of-pages paragraph than always seeking to its start.
    private func estimatedChunk(inGroup group: [Int], atProportion proportion: Double) -> Int {
        let texts = visibleChunkTexts
        let lengths = group.map { texts.indices.contains($0) ? Double(texts[$0].count) : 0 }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return group.first ?? 0 }
        let target = proportion * total
        var cumulative: Double = 0
        for (i, length) in lengths.enumerated() {
            cumulative += length
            if target <= cumulative { return group[i] }
        }
        return group.last ?? 0
    }
}
