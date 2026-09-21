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

/// The music-player screen for a chapter: the whole page is the read-along
/// text, with a compact, translucent transport bar floating over its
/// bottom (elapsed/total time on top, avatar + −10s/play-pause/+10s
/// below) — text keeps scrolling underneath it, it doesn't reserve its own
/// space.
/// Reachable both from a saved chapter (`ChaptersListView` → `playSaved`)
/// and from Play on one that hasn't been generated yet (→ `stream`) — the
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
    let chapterRef: ChapterRef
    @ObservedObject var chapterPlayer: ChapterAudioPlayer

    @State private var isAutoScrollPaused = false
    @State private var visibleParagraphs: Set<Int> = []
    @State private var isPlayerCollapsed = false
    @Namespace private var floatingPlayerNamespace
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
    // Persisted across sessions — set once, stays that way for every chapter
    // opened afterward. See the ⋯ menu (ChapterPlayerOptionsSheet).
    @AppStorage("chapterPlayerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("chapterPlayerShowFloatingPlayer") private var showFloatingPlayer = true
    @AppStorage("chapterPlayerAutoScrollEnabled") private var autoScrollEnabled = true
    @AppStorage("chapterPlayerFontSize") private var readerFontSize: ReaderFontSize = .medium
    @AppStorage("chapterPlayerTheme") private var readerTheme: ReaderTheme = .carbon

    private var chapter: Chapter? {
        project.chapters.first { $0.index == chapterRef.chapterIndex }
    }

    // Falls back to one group per chunk before .onAppear populates
    // paragraphGroups, so the very first render matches today's per-chunk
    // layout instead of showing nothing.
    private var effectiveGroups: [[Int]] {
        paragraphGroups.isEmpty ? chapterPlayer.chunkTexts.indices.map { [$0] } : paragraphGroups
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            readAlong
            if showFloatingPlayer {
                floatingPlayer
            }
        }
        .background(readerTheme.background.ignoresSafeArea())
        .navigationTitle(chapter?.title ?? "Chapter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
                fontSize: $readerFontSize,
                theme: $readerTheme)
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
        // Fires once per chunk as streaming synthesizes it (duration only
        // grows in that mode — see ChapterAudioPlayer.stream), which is
        // exactly when a paragraph's words need to upgrade from the plain-
        // text fallback to real word timings. Not a per-frame cost.
        .onChange(of: chapterPlayer.duration) { _, _ in
            recomputeWordItems()
        }
        .onAppear {
            isAutoScrollPaused = false
            isPlayerCollapsed = false
            paragraphGroups = computeParagraphGroups()
            recomputeWordItems()
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            // Unconditional, not just "if keepScreenOn" — this is a
            // process-global flag, and leaving with the toggle on must not
            // keep the rest of the app from ever auto-locking.
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
            // First population (or the group count somehow changed) —
            // start every revision at 0. Safe to leave rows un-bumped
            // here: wordItems(for:) is deterministic, so these match
            // whatever the first frame's fallback already rendered.
            paragraphWordItems = fresh
            paragraphRevisions = Array(repeating: 0, count: fresh.count)
            return
        }
        var revisions = paragraphRevisions
        for index in fresh.indices where fresh[index] != paragraphWordItems[index] {
            revisions[index] += 1
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
        let texts = chapterPlayer.chunkTexts
        guard let fullText = chapter?.text, texts.count > 1 else {
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
                gaps[index] = fullText[previousEnd..<range.lowerBound].contains(where: \.isNewline)
            }
            previousEnd = range.upperBound
            searchStart = range.upperBound
        }
        return gaps
    }

    // MARK: - Floating player

    private var floatingPlayer: some View {
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

    // Liquid Glass is only available on iOS 26+. Tinting it with the active
    // reader palette keeps both light and dark player cards visually tied
    // to the page. The explicit themed fallback does the same on iOS 17–25.
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
            chapterPlayer.togglePlayPause()
        } label: {
            LucideIcon(
                chapterPlayer.isPlaying ? .circlePause : .circlePlay, size: 44,
                color: readerTheme.primaryText
            )
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chapterPlayer.isPlaying ? "Pause" : "Play")
        .opacity(isPulsingPlayButton ? 0.5 : 1)
        .onAppear { updatePlayButtonPulse(isBuffering: chapterPlayer.isBuffering) }
        .onChange(of: chapterPlayer.isBuffering) { _, isBuffering in
            updatePlayButtonPulse(isBuffering: isBuffering)
        }
        .matchedGeometryEffect(id: "playPauseButton", in: floatingPlayerNamespace)
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
                                        group: group, groupIndex: groupIndex, localY: value.location.y)
                                }
                            )
                            .modifier(
                                ReaderScrollVisibilityObserver { isVisible in
                                    if isVisible {
                                        visibleParagraphs.insert(groupIndex)
                                    } else {
                                        visibleParagraphs.remove(groupIndex)
                                    }
                                })
                    }
                }
                .padding()
                // Clears the floating player so the last few lines of text
                // aren't permanently hidden underneath it.
                .padding(
                    .bottom,
                    showFloatingPlayer ? (isPlayerCollapsed ? 48 : 100) : 0)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    guard autoScrollEnabled, !isAutoScrollPaused else { return }
                    isAutoScrollPaused = true
                }
            )
            .onChange(of: chapterPlayer.currentChunkIndex) { _, chunkIndex in
                guard autoScrollEnabled, !isAutoScrollPaused else { return }
                guard let (groupIndex, anchor) = scrollTarget(forChunk: chunkIndex) else { return }
                withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
            }
            .overlay(alignment: .top) {
                if autoScrollEnabled, isAutoScrollPaused, isCurrentParagraphOffscreen {
                    TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                        currentWordResumeButton {
                            isAutoScrollPaused = false
                            if let (groupIndex, anchor) = scrollTarget(
                                forChunk: chapterPlayer.currentChunkIndex)
                            {
                                withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var isCurrentParagraphOffscreen: Bool {
        guard let groupIndex = effectiveGroups.firstIndex(where: {
            $0.contains(chapterPlayer.currentChunkIndex)
        }) else { return false }
        return !visibleParagraphs.contains(groupIndex)
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
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            Button(action: action) { currentWordResumeLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to current word: \(currentSpokenWord)")
                .background(.ultraThinMaterial, in: Capsule())
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
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        let isCurrentGroup = group.contains(chapterPlayer.currentChunkIndex) && chapterPlayer.isPlaying
        let hasAnyWordTimings = items.contains { $0.wordIndexInChunk != nil }

        return Group {
            if hasAnyWordTimings, isCurrentGroup {
                TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                    ParagraphRow(
                        items: items, itemsRevision: revision,
                        highlightedChunkIndex: chapterPlayer.currentChunkIndex,
                        highlightedWordIndex: chapterPlayer.currentWordIndex(
                            atElapsed: chapterPlayer.currentPlaybackTime),
                        isCurrentGroup: true,
                        fontSize: readerFontSize,
                        theme: readerTheme
                    ).equatable()
                }
            } else {
                ParagraphRow(
                    items: items, itemsRevision: revision,
                    highlightedChunkIndex: nil, highlightedWordIndex: nil,
                    isCurrentGroup: isCurrentGroup,
                    fontSize: readerFontSize,
                    theme: readerTheme
                ).equatable()
            }
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
        let theme: ReaderTheme

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.itemsRevision == rhs.itemsRevision && lhs.highlightedChunkIndex == rhs.highlightedChunkIndex
                && lhs.highlightedWordIndex == rhs.highlightedWordIndex && lhs.isCurrentGroup == rhs.isCurrentGroup
                && lhs.fontSize == rhs.fontSize && lhs.theme == rhs.theme
        }

        var body: some View {
            WordFlowLayout(horizontalSpacing: 2, verticalSpacing: 2, paragraphExtraSpacing: 6) {
                // items.indices, not Array(items.enumerated()) — the
                // latter allocates a fresh tuple array on every body run,
                // which for the playing paragraph is 12x/sec.
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    let isHighlighted =
                        isCurrentGroup && item.chunkIndex == highlightedChunkIndex
                            && item.wordIndexInChunk == highlightedWordIndex
                    Text(item.text)
                        .font(fontSize.font)
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
        var items: [FlowWordItem] = []
        for chunkIndex in group {
            let timings = chapterPlayer.wordTimings(forChunk: chunkIndex)
            let isFirstChunkInGroup = chunkIndex == group.first
            if timings.isEmpty {
                let tokens = WordTimingDeriver.splitPreservingSeparators(chapterPlayer.chunkTexts[chunkIndex])
                for (i, token) in tokens.enumerated() {
                    let breaks = (isFirstChunkInGroup && i == 0) || i == 0
                        ? 0 : token.precedingSeparator.filter { $0 == "\n" }.count
                    items.append(
                        FlowWordItem(
                            text: token.word, chunkIndex: chunkIndex, wordIndexInChunk: nil,
                            lineBreaksBefore: breaks))
                }
            } else {
                for (i, timing) in timings.enumerated() {
                    // A boundary INSIDE one group is, by definition, never
                    // a real line break (that's what makes it one group
                    // instead of two), so the first word of every chunk
                    // after the group's first just flows on — only a real
                    // precedingSeparator ("\n"/"\n\n", from a chunk's own
                    // internal words) forces a break.
                    let breaks = (isFirstChunkInGroup && i == 0) || i == 0
                        ? 0 : timing.precedingSeparator.filter { $0 == "\n" }.count
                    items.append(
                        FlowWordItem(
                            text: timing.word, chunkIndex: chunkIndex, wordIndexInChunk: i,
                            lineBreaksBefore: breaks))
                }
            }
        }
        return items
    }

    private func handleParagraphTap(group: [Int], groupIndex: Int, localY: CGFloat) {
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
        let lengths = group.map { Double(chapterPlayer.chunkTexts[$0].count) }
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
