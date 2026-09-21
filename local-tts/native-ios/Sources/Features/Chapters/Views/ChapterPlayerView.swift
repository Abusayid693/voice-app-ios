import LucideSwift
import SwiftUI
import UIKit

/// The music-player screen for a chapter: the whole page is the read-along
/// text, with a compact, translucent transport bar floating over its
/// bottom (scrubber on top, avatar + −10s/play-pause/+10s below) — text
/// keeps scrolling underneath it, it doesn't reserve its own space. The
/// transport bar fades out after a few seconds of inactivity (so it
/// doesn't sit over the text while the user's just reading/listening) and
/// fades back in on any tap on the page — see showControlsTemporarily.
/// Reachable both from a saved chapter (`ChaptersListView` → `playSaved`)
/// and from Play on one that hasn't been generated yet (→ `stream`) — the
/// two feed identical scrubber/highlighting behavior through
/// `ChapterAudioPlayer`'s shared published surface (`duration`/`elapsed`/
/// `wordTimings(forChunk:)`/etc.), which is kept correct for both modes
/// internally; this view doesn't know or care which one is active. The one
/// real difference during streaming: `duration` grows as chunks arrive
/// rather than being known upfront, and seeking is clamped to what's
/// already been synthesized — both handled inside `ChapterAudioPlayer`.
///
/// The read-along portion — the 2-second user-scroll override and the
/// "Jump to current" pill — is lifted verbatim from the retired
/// `ReadAlongPlayerView`. Highlighting is word-level for English Kokoro
/// chunks (see `WordTimingDeriver`) — every chunk's own word-timings entry
/// drives this; an empty entry (non-English voice, a manifest saved before
/// this feature existed, or — during streaming — a chunk not yet
/// synthesized) falls back to highlighting the whole chunk, same as before.
struct ChapterPlayerView: View {
    let project: SavedGeneration
    let chapterRef: ChapterRef
    @ObservedObject var chapterPlayer: ChapterAudioPlayer

    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var scrubberValue: Double = 0
    @State private var isScrubbing = false
    // Chunks that belong to the same paragraph in the chapter's own source
    // text, grouped so they render as one continuous Text — one row per
    // paragraph, not one row per ~350-char synthesis chunk (see
    // computeParagraphGroups). Computed once on appear, not as a plain
    // computed property: body re-evaluates at 4Hz while playing
    // (chapterPlayer's ticker), and this does an O(n) string search over
    // the chapter text.
    @State private var paragraphGroups: [[Int]] = []
    // Each group's rendered height, measured via a GeometryReader
    // background in readAlong — used to estimate which chunk within a
    // multi-chunk paragraph a tap landed on (see handleParagraphTap).
    @State private var groupHeights: [Int: CGFloat] = [:]
    // Whether the floating transport bar is showing — starts visible, then
    // fades out after a few seconds of no interaction and back in on any
    // tap. See showControlsTemporarily, called from every real interaction
    // point (transport buttons, scrubbing, tap-to-seek) rather than relying
    // on gesture propagation from one page-wide tap, which could otherwise
    // get eaten by a paragraph row's own tap-to-seek gesture.
    @State private var isControlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    // Play/pause button pulses opacity while nothing is playable yet
    // (chapterPlayer.isBuffering — true entering the player before
    // streaming's first chunk lands, or between chunks if playback ever
    // catches up to the synthesis frontier).
    @State private var isPulsingPlayButton = false
    @State private var isOptionsSheetPresented = false
    // Both persisted across sessions — set once, stays that way for every
    // chapter opened afterward. See the ⋯ menu (ChapterPlayerOptionsSheet).
    @AppStorage("chapterPlayerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("chapterPlayerShowFloatingPlayer") private var showFloatingPlayer = true

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
            // showFloatingPlayer is the persisted "off" switch — fully
            // hidden, no tap-to-reveal, regardless of isControlsVisible's
            // own auto-hide ticking. isControlsVisible still layers the
            // existing fade-after-inactivity behavior on top when it's on.
            if showFloatingPlayer, isControlsVisible {
                floatingPlayer
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isControlsVisible)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(chapter?.title ?? "Chapter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isOptionsSheetPresented = true
                } label: {
                    LucideIcon(.ellipsis, color: Color.appPrimaryText)
                }
            }
        }
        .sheet(isPresented: $isOptionsSheetPresented) {
            ChapterPlayerOptionsSheet(keepScreenOn: $keepScreenOn, showFloatingPlayer: $showFloatingPlayer)
        }
        .preferredColorScheme(.dark)
        // Catch-all for a tap that lands on plain background rather than a
        // specific control — simultaneousGesture so it never blocks a
        // paragraph row's own tap-to-seek or the ScrollView's own drag.
        .simultaneousGesture(TapGesture().onEnded { showControlsTemporarily() })
        .onChange(of: chapterPlayer.elapsed) { _, newValue in
            guard !isScrubbing else { return }
            scrubberValue = newValue
        }
        .onChange(of: keepScreenOn) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onAppear {
            paragraphGroups = computeParagraphGroups()
            scheduleHideControls()
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            // Unconditional, not just "if keepScreenOn" — this is a
            // process-global flag, and leaving with the toggle on must not
            // keep the rest of the app from ever auto-locking.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // Cancels any pending auto-hide, shows the bar (if it was hidden), and
    // starts a fresh countdown — call this from every real interaction
    // with the page, not just the catch-all background tap.
    private func showControlsTemporarily() {
        hideControlsTask?.cancel()
        isControlsVisible = true
        scheduleHideControls()
    }

    private func scheduleHideControls() {
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Skip this cycle rather than hiding out from under an active
            // scrub — endScrub already calls showControlsTemporarily,
            // which reschedules once the user actually lets go.
            guard !Task.isCancelled, !isScrubbing else { return }
            isControlsVisible = false
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
        VStack(spacing: 14) {
            scrubber
            transportRow
        }
        .padding(16)
        .background(Color.appSecondaryBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: $scrubberValue, in: 0...max(chapterPlayer.duration, 1),
                onEditingChanged: { editing in
                    showControlsTemporarily()
                    if editing {
                        isScrubbing = true
                        chapterPlayer.beginScrub()
                    } else {
                        isScrubbing = false
                        chapterPlayer.endScrub(to: scrubberValue)
                    }
                }
            )
            .tint(Color.appPrimaryText)

            HStack {
                Text(Self.formatTime(scrubberValue)).appText(.meta).monospacedDigit()
                Spacer()
                Text(Self.formatTime(chapterPlayer.duration)).appText(.meta).monospacedDigit()
            }
        }
    }

    private var transportRow: some View {
        HStack {
            avatar

            Spacer()

            HStack(spacing: 28) {
                skipButton(icon: .rotateCcw, label: "10") {
                    showControlsTemporarily()
                    chapterPlayer.skipBackward()
                }

                Button(action: {
                    showControlsTemporarily()
                    chapterPlayer.togglePlayPause()
                }) {
                    LucideIcon(
                        chapterPlayer.isPlaying ? .circlePause : .circlePlay, size: 44,
                        color: Color.appPrimaryText)
                }
                .buttonStyle(.plain)
                .opacity(isPulsingPlayButton ? 0.5 : 1)
                .onAppear { updatePlayButtonPulse(isBuffering: chapterPlayer.isBuffering) }
                .onChange(of: chapterPlayer.isBuffering) { _, isBuffering in
                    updatePlayButtonPulse(isBuffering: isBuffering)
                }

                skipButton(icon: .rotateCw, label: "10") {
                    showControlsTemporarily()
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
                LucideIcon(icon, size: 28, color: Color.appPrimaryText)
                Text(label).appText(.meta)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Read-along text

    private var readAlong: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(effectiveGroups.indices, id: \.self) { groupIndex in
                        let group = effectiveGroups[groupIndex]
                        paragraphGroupView(group: group, groupIndex: groupIndex)
                            .id(groupIndex)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear { groupHeights[groupIndex] = geo.size.height }
                                        .onChange(of: geo.size.height) { _, newValue in
                                            groupHeights[groupIndex] = newValue
                                        }
                                }
                            )
                            .gesture(
                                SpatialTapGesture().onEnded { value in
                                    handleParagraphTap(
                                        group: group, groupIndex: groupIndex, localY: value.location.y)
                                }
                            )
                    }
                }
                .padding()
                // Clears the floating player so the last few lines of text
                // aren't permanently hidden underneath it.
                .padding(.bottom, 140)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    showControlsTemporarily()
                    isUserScrolling = true
                    scrollResumeTask?.cancel()
                    scrollResumeTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        isUserScrolling = false
                    }
                }
            )
            .onChange(of: chapterPlayer.currentChunkIndex) { _, chunkIndex in
                guard !isUserScrolling else { return }
                guard let (groupIndex, anchor) = scrollTarget(forChunk: chunkIndex) else { return }
                withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
            }
            .overlay(alignment: .top) {
                if isUserScrolling {
                    Button("Jump to current") {
                        scrollResumeTask?.cancel()
                        isUserScrolling = false
                        if let (groupIndex, anchor) = scrollTarget(forChunk: chapterPlayer.currentChunkIndex) {
                            withAnimation { proxy.scrollTo(groupIndex, anchor: anchor) }
                        }
                    }
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.ghostButtonText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                }
            }
        }
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

    private func paragraphGroupView(group: [Int], groupIndex: Int) -> some View {
        let isCurrentGroup = group.contains(chapterPlayer.currentChunkIndex) && chapterPlayer.isPlaying
        let hasAnyWordTimings = group.contains { !chapterPlayer.wordTimings(forChunk: $0).isEmpty }
        return Group {
            if hasAnyWordTimings, isCurrentGroup {
                // 0.08s (~12 Hz): fine enough that a word swap doesn't
                // read as a stutter, without publishing at that rate on
                // ChapterAudioPlayer itself — see currentPlaybackTime.
                // Only the currently-playing paragraph polls; every other
                // row renders once.
                TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                    paragraphText(group: group)
                }
            } else {
                paragraphText(group: group)
            }
        }
        .padding(6)
        .background(
            isCurrentGroup ? Color.chunkHighlightBackground : Color.clear,
            in: RoundedRectangle(cornerRadius: 8))
    }

    // Flows every chunk in this paragraph group's words through
    // WordFlowLayout, so a paragraph the synthesis chunker had to cut for
    // its ~350-char budget still wraps and reads as continuous prose
    // instead of breaking mid-line at the cut — while still letting the
    // single currently-playing word carry its own rounded background
    // highlight, which plain Text concatenation can't do (there's no way
    // to give one piece within a `Text + Text` run its own background).
    // All word text is one color at full opacity; only the word background
    // (and the paragraph box in paragraphGroupView) signal position now.
    // Every word carries constant padding regardless of highlight state —
    // varying it would resize the word and reflow the paragraph as the
    // highlight moves, the same class of bug the earlier construction-
    // method-consistency fix addressed.
    private func paragraphText(group: [Int]) -> some View {
        let isCurrentGroup = group.contains(chapterPlayer.currentChunkIndex) && chapterPlayer.isPlaying
        let currentChunkIndex = chapterPlayer.currentChunkIndex
        let currentWord =
            isCurrentGroup ? chapterPlayer.currentWordIndex(atElapsed: chapterPlayer.currentPlaybackTime) : nil

        return WordFlowLayout(horizontalSpacing: 2, verticalSpacing: 2, paragraphExtraSpacing: 6) {
            ForEach(Array(wordItems(for: group).enumerated()), id: \.offset) { _, item in
                let isHighlighted =
                    isCurrentGroup && item.chunkIndex == currentChunkIndex && item.wordIndexInChunk == currentWord
                Text(item.text)
                    .font(AppTextStyle.reading.font)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        isHighlighted ? Color.wordHighlightBackground : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
                    .lineBreaksBefore(item.lineBreaksBefore)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    private struct FlowWordItem {
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
        showControlsTemporarily()
        let target: Int
        if group.count > 1 {
            let height = groupHeights[groupIndex] ?? 0
            let proportion = height > 0 ? Double(max(0, min(localY, height)) / height) : 0
            target = estimatedChunk(inGroup: group, atProportion: proportion)
        } else {
            target = group[0]
        }
        guard let start = chapterPlayer.startTime(forChunk: target) else { return }
        chapterPlayer.seek(to: start)
        scrubberValue = start
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
