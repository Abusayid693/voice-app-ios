import LucideSwift
import SwiftUI

/// The music-player screen for a generated chapter: the whole page is the
/// read-along text, with a compact, translucent transport bar floating over
/// its bottom (scrubber on top, avatar + −10s/play-pause/+10s below) —
/// text keeps scrolling underneath it, it doesn't reserve its own space.
/// Only reachable for a chapter that's actually been saved (`ChaptersListView`
/// pushes here from `playSaved`, never from streaming) — real
/// duration/elapsed/seek only exist once a chapter's chunks are merged into
/// one file (see `ChapterAudioManifest`).
///
/// The read-along portion — the 2-second user-scroll override, the "Jump
/// to current" pill, and the chunk highlight treatment — is lifted
/// verbatim from the retired `ReadAlongPlayerView` (see
/// docs/adr/0005-chunk-level-read-along-highlighting.md for why
/// highlighting is chunk-level, not word-level).
struct ChapterPlayerView: View {
    let project: SavedGeneration
    let chapterRef: ChapterRef
    @ObservedObject var chapterPlayer: ChapterAudioPlayer

    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var scrubberValue: Double = 0
    @State private var isScrubbing = false

    private var chapter: Chapter? {
        project.chapters.first { $0.index == chapterRef.chapterIndex }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            readAlong
            floatingPlayer
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(chapter?.title ?? "Chapter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
        .onChange(of: chapterPlayer.elapsed) { _, newValue in
            guard !isScrubbing else { return }
            scrubberValue = newValue
        }
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
                skipButton(icon: .rotateCcw, label: "10") { chapterPlayer.skipBackward() }

                Button(action: chapterPlayer.togglePlayPause) {
                    LucideIcon(
                        chapterPlayer.isPlaying ? .circlePause : .circlePlay, size: 44,
                        color: Color.appPrimaryText)
                }
                .buttonStyle(.plain)

                skipButton(icon: .rotateCw, label: "10") { chapterPlayer.skipForward() }
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
                    ForEach(chapterPlayer.chunkTexts.indices, id: \.self) { index in
                        chunkText(index: index)
                            .id(index)
                            .onTapGesture {
                                guard let start = chapterPlayer.startTime(forChunk: index) else { return }
                                chapterPlayer.seek(to: start)
                                scrubberValue = start
                            }
                    }
                }
                .padding()
                // Clears the floating player so the last few lines of text
                // aren't permanently hidden underneath it.
                .padding(.bottom, 140)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
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
                withAnimation { proxy.scrollTo(chunkIndex, anchor: .center) }
            }
            .overlay(alignment: .top) {
                if isUserScrolling {
                    Button("Jump to current") {
                        scrollResumeTask?.cancel()
                        isUserScrolling = false
                        withAnimation { proxy.scrollTo(chapterPlayer.currentChunkIndex, anchor: .center) }
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

    private func chunkText(index: Int) -> some View {
        let isCurrentChunk = index == chapterPlayer.currentChunkIndex && chapterPlayer.isPlaying
        return Text(chapterPlayer.chunkTexts[index])
            .appText(isCurrentChunk ? .reading : .readingMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(
                isCurrentChunk ? Color.appSecondaryBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
    }
}
