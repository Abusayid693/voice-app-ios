import LucideSwift
import SwiftUI

/// Which presentation `ChapterPlayerView` is showing. All three render the
/// same playback session from the same player, so switching between them
/// changes only what's on screen.
enum ReaderSurfaceMode: String, CaseIterable {
    /// Read-along text with chunk and word highlighting.
    case text
    /// The imported document's own page image, with the playing chunk
    /// highlighted on it. Only reachable for PDFs that kept their source.
    case originalPage
    /// Music-style artwork, scrubber and transport.
    case audio
}

/// The audio surface: artwork, a title block, a thin scrubber with its
/// elapsed/remaining pair, transport, and — where a music player puts its
/// volume slider — this book's whole-book progress instead, since a book is
/// the thing being progressed through here and system volume already has a
/// hardware control.
///
/// A *branch of* `ChapterPlayerView`, not a screen of its own: the toolbar
/// above it, the navigation it sits in, and the player driving it all
/// belong to the reader, so toggling to read-along is a view change that
/// playback never notices. It was a `.fullScreenCover` while music mode was
/// a separate feature; see `docs/adr/0013-unified-player.md`.
struct NowPlayingSurface: View {
    @ObservedObject var player: BookAudioPlayer
    /// Book identity comes from the reader, not the player: this surface is
    /// reachable *before* anything is playing (the shelf's headphones button
    /// opens straight onto it), and the player carries no book at all until
    /// `start(...)` runs. Reading cover and title off the player left this
    /// screen blank on exactly that path.
    let coverURL: URL?
    let title: String
    let pageIndex: Int
    let pageCount: Int
    /// Whether the player's live values (playing, buffering, elapsed,
    /// duration) describe *this* page. False when nothing is playing yet, or
    /// when the player is on some other book.
    let isActive: Bool
    /// Keeps the audio content below an overlaid reader header while the
    /// ambient artwork background still fills the entire screen behind it.
    let topContentInset: CGFloat
    /// Routed back to the reader rather than calling the player directly,
    /// so play starts a session when there isn't one — `togglePlayPause`
    /// alone no-ops against an idle player.
    let onTogglePlayPause: () -> Void
    let onSelectPage: (Int) -> Void

    @State private var coverImage: UIImage?
    @State private var scrubberValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topContentInset)
                    .accessibilityHidden(true)
                cover(height: coverHeight(in: geometry))
                Spacer(minLength: 16)
                titleBlock
                Spacer(minLength: 14)
                scrubberBlock
                Spacer(minLength: 10)
                transport
                Spacer(minLength: 18)
                bookProgressRow
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        }
        // Applied as a background rather than a ZStack sibling on purpose:
        // `scaledToFill` lets the artwork exceed the size it's proposed and
        // `.clipped()` only clips *rendering*, not layout — as a sibling it
        // inflated the ZStack, so the GeometryReader beside it was proposed
        // an oversized width and every row inside spilled off both edges.
        // A `.background` can never influence its host's size.
        .background { ambientBackground }
        .task(id: coverURL) {
            coverImage = coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
        .onChange(of: player.elapsed) { _, newValue in
            guard !isScrubbing else { return }
            scrubberValue = newValue
        }
    }

    /// Whatever's left once the fixed rows below the artwork have taken
    /// theirs — a fixed cover size overflowed an SE-class screen, and in
    /// landscape there's barely any vertical room at all.
    private func coverHeight(in geometry: GeometryProxy) -> CGFloat {
        let reservedBelowCover: CGFloat = 330
        let available = geometry.size.height - reservedBelowCover - topContentInset
        // 2:3, so the width it implies also has to fit the side padding —
        // and a further margin of its own (`- 100`, not just the screen's
        // `- 56` side padding), so the cover reads as artwork sitting on
        // the page rather than art that fills it edge to edge.
        let widthLimited = (geometry.size.width - 100) * 3 / 2
        return max(120, min(min(available, widthLimited), 260))
    }

    // MARK: - Background

    /// The artwork itself, blown up and blurred into a colour wash — the
    /// same ambient treatment `VoicePreviewSheet.cardBackground` uses, at a
    /// larger radius and a lighter scrim so the cover's own colour carries
    /// the screen rather than being flattened to grey.
    private var ambientBackground: some View {
        ZStack {
            Color.appBackground
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 60, opaque: true)
                    .saturation(1.6)
                    .opacity(0.75)
            }
            // Darkened towards the bottom, where the controls sit, so white
            // text and a white knob stay legible over a pale cover.
            LinearGradient(
                colors: [
                    Color.appBackground.opacity(0.25),
                    Color.appBackground.opacity(0.55),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - Cover

    private func cover(height: CGFloat) -> some View {
        SavedProjectCover(
            coverURL: coverURL, title: title,
            size: CGSize(width: height * 2 / 3, height: height), cornerRadius: 12)
            .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
    }

    // MARK: - Title

    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                Text("Page \(pageIndex + 1) of \(pageCount)")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.appPrimaryText.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Page scrubber

    private var scrubberBlock: some View {
        VStack(spacing: 2) {
            PlaybackScrubber(
                value: $scrubberValue,
                range: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        player.beginScrub()
                    } else {
                        isScrubbing = false
                        player.endScrub(to: scrubberValue)
                    }
                }
            )
            .disabled(duration <= 0)
            .opacity(duration <= 0 ? 0.4 : 1)

            HStack {
                Text(Self.formatted(displayedElapsed))
                Spacer()
                Text("-\(Self.formatted(max(duration - displayedElapsed, 0)))")
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.appPrimaryText.opacity(0.55))
        }
    }

    private var isPlaying: Bool { isActive && player.isPlaying }
    private var duration: TimeInterval { isActive ? player.duration : 0 }

    /// Whole-book fraction. Falls back to the page the reader is showing so
    /// the bar is meaningful before playback starts, rather than sitting at
    /// zero until the first chunk lands.
    private var bookProgress: Double {
        guard pageCount > 0 else { return 0 }
        if isActive { return player.bookProgress }
        return Double(pageIndex) / Double(pageCount)
    }

    private var displayedElapsed: TimeInterval {
        isScrubbing ? scrubberValue : (isActive ? player.elapsed : 0)
    }

    // MARK: - Transport

    /// `Spacer`s rather than fixed `HStack` spacing: the five controls are
    /// 240pt of fixed frames on their own, and at any spacing wide enough to
    /// look right on a large phone the row overflowed both edges on a
    /// narrower one (a 375pt screen offers 319pt inside this screen's 28pt
    /// side padding).
    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("backward.end.fill", size: 20, accessibilityLabel: "Previous page") {
                onSelectPage(pageIndex - 1)
            }
            .disabled(pageIndex <= 0)

            Spacer(minLength: 0)

            transportButton("gobackward.15", size: 30, accessibilityLabel: "Back 15 seconds") {
                player.skipBackward()
            }
            .disabled(!isActive)

            Spacer(minLength: 0)

            playPauseButton

            Spacer(minLength: 0)

            transportButton("goforward.15", size: 30, accessibilityLabel: "Forward 15 seconds") {
                player.skipForward()
            }
            .disabled(!isActive)

            Spacer(minLength: 0)

            transportButton("forward.end.fill", size: 20, accessibilityLabel: "Next page") {
                onSelectPage(pageIndex + 1)
            }
            .disabled(pageIndex + 1 >= pageCount)
        }
        .frame(maxWidth: .infinity)
    }

    private var playPauseButton: some View {
        PlayPauseBounceButton(
            isPlaying: isPlaying, tapTargetSize: 68, action: onTogglePlayPause
        ) { isPlaying in
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
        }
        .overlay {
            if isActive, player.isBuffering {
                // Date-driven rather than a `repeatForever` state animation,
                // for the reason `ChapterPlayerView`'s own buffering ring
                // documents: a view that mounts after such an animation
                // began doesn't retroactively animate with it.
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            Color.appPrimaryText.opacity(0.9),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(bufferingRingAngle(at: context.date)))
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    /// SF Symbols rather than this app's usual Lucide set for the transport
    /// specifically: Lucide's glyphs are stroke-only, which reads as thin
    /// outlines beside a filled play button, and it has no "skip 15
    /// seconds" glyph at all — `gobackward.15`/`goforward.15` say exactly
    /// what these buttons do.
    private func transportButton(
        _ systemName: String, size: CGFloat, accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Whole-book progress

    /// Sits where a music player's volume slider would, and reads the same
    /// way — a small glyph either side of a thin bar. Deliberately not
    /// draggable: a whole-book seek could land on a page far outside the
    /// synthesis lookahead window, with nothing bounding how long it would
    /// buffer for. The page scrubber above is the one that moves.
    private var bookProgressRow: some View {
        HStack(spacing: 10) {
            LucideIcon(.book, size: 13, color: Color.appPrimaryText.opacity(0.55))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.appPrimaryText.opacity(0.22))
                    Capsule()
                        .fill(Color.appPrimaryText.opacity(0.7))
                        .frame(width: geometry.size.width * CGFloat(min(max(bookProgress, 0), 1)))
                }
            }
            .frame(height: 4)
            Text("\(Int((min(max(bookProgress, 0), 1) * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText.opacity(0.55))
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Book progress")
        .accessibilityValue("\(Int((min(max(bookProgress, 0), 1) * 100).rounded())) percent")
    }

    private func bufferingRingAngle(at date: Date) -> Double {
        let period = 1.0
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return (elapsed / period) * 360
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NowPlayingSurface(
        player: app.player, coverURL: nil, title: "A Book", pageIndex: 2, pageCount: 326,
        isActive: false, topContentInset: 0,
        onTogglePlayPause: {}, onSelectPage: { _ in })
}
