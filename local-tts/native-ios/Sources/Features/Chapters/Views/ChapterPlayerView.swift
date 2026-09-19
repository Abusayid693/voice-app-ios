import LucideSwift
import SwiftUI

/// The music-player screen for a generated chapter: artwork/title/voice +
/// a real draggable scrubber up top, the chapter's read-along text
/// scrolling and highlighting underneath. Only reachable for a chapter
/// that's actually been saved (`ChaptersListView` pushes here from
/// `playSaved`, never from streaming) — real duration/elapsed/seek only
/// exist once a chapter's chunks are merged into one file (see
/// `ChapterAudioManifest`).
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
        VStack(spacing: 0) {
            header
            readAlong
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onChange(of: chapterPlayer.elapsed) { _, newValue in
            guard !isScrubbing else { return }
            scrubberValue = newValue
        }
    }

    // MARK: - Now-playing header

    private var header: some View {
        VStack(spacing: 16) {
            artwork
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 4) {
                Text(chapter?.title ?? "Chapter").appText(.title)
                Text(VoiceDisplayName.forCode(project.voiceName)).appText(.body)
            }

            scrubber

            Button(action: chapterPlayer.togglePlayPause) {
                LucideIcon(
                    chapterPlayer.isPlaying ? .circlePause : .circlePlay, size: 56,
                    color: Color.appPrimaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background {
            artwork
                .blur(radius: 30)
                .opacity(0.4)
                .overlay(Color.appBackground.opacity(0.55))
                .clipped()
        }
    }

    private var artwork: some View {
        Image(VoiceCoverArt.assetName(for: project.voiceName))
            .resizable()
            .scaledToFill()
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
