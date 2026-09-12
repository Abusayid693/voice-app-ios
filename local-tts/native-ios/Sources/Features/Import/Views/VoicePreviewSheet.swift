import LucideSwift
import SwiftUI

/// Half-height sheet reached by tapping a Trending voices row — presented as
/// a horizontally scrolling carousel of *whole sheet cards*, one per voice,
/// with the neighbouring voices' cards peeking in at both edges.
///
/// The system sheet itself is made invisible (`.presentationBackground(.clear)`)
/// and every card is drawn by us instead. That's deliberate: a system sheet
/// draws one fixed rounded container, so anything paged *inside* it (a
/// TabView, say) slides its contents within a frame that never moves — which
/// reads as "only the inner content changed". Hosting our own cards means the
/// entire sheet visibly slides off to one side while the next voice's sheet
/// slides in, which is the intended interaction.
///
/// Paging/snapping is iOS 17's `.scrollTargetBehavior(.viewAligned)` rather
/// than `TabView(.page)` — TabView pages are always exactly container-width,
/// so it can't show the adjacent cards peeking or put real gaps between them.
struct VoicePreviewSheet: View {
    let tiles: [VoiceTile]
    let initialTileID: String
    @ObservedObject var viewModel: TTSViewModel

    @State private var currentTileID: String?

    /// Horizontal inset on each side of the focused card. The neighbouring
    /// card peeks in by `cardPeek - cardSpacing`, so these two together set
    /// how much of the next voice is visible at rest.
    private let cardPeek: CGFloat = 28
    private let cardSpacing: CGFloat = 12

    init(tiles: [VoiceTile], initialTileID: String, viewModel: TTSViewModel) {
        self.tiles = tiles
        self.initialTileID = initialTileID
        self.viewModel = viewModel
        _currentTileID = State(initialValue: initialTileID)
    }

    var body: some View {
        // The card width is computed from the real container width rather
        // than via containerRelativeFrame: that measures the container
        // *after* contentMargins has already inset it, so subtracting the
        // peek again there makes the card two peeks too narrow and the
        // resting card sits off-centre (small gap left, large gap right).
        GeometryReader { geometry in
            let cardWidth = max(geometry.size.width - cardPeek * 2, 0)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // Lazy, not a plain HStack: every card carries a
                    // full-size blurred cover image, and there are 50+
                    // voices — building them all up front would be
                    // needlessly heavy.
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(tiles) { tile in
                            VoicePreviewCard(tile: tile, viewModel: viewModel)
                                .frame(width: cardWidth)
                                .id(tile.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentTileID)
                // Tells the scroll view to align snapped cards to an edge
                // inset by cardPeek, so the resting card spans exactly
                // cardPeek...(width - cardPeek) — equal gap on both sides.
                .contentMargins(.horizontal, cardPeek, for: .scrollContent)
                .scrollIndicators(.hidden)
                .onAppear {
                    // scrollPosition's initial value doesn't reliably land
                    // on first render, and opening voice #40 must not start
                    // at #1.
                    proxy.scrollTo(initialTileID, anchor: .center)
                }
            }
        }
        .padding(.vertical, 16)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // Hides the system sheet's own card so ours are the only ones on
        // screen — see the type's doc comment.
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        // Scrolling to another voice always stops whatever was playing — its
        // audio would otherwise keep going under a different voice's card.
        // Doesn't auto-start the new one; matches today's tap-to-play.
        .onChange(of: currentTileID) { _, _ in
            viewModel.stopPreview()
        }
        .onDisappear {
            viewModel.stopPreview()
        }
    }
}

/// One voice's sheet card: ambient blurred cover backdrop, cover art
/// (blob-deformed while playing), name/engine label, progress track and
/// play button — the whole thing rounded and clipped so it reads as its own
/// sheet rather than content inside a shared one.
private struct VoicePreviewCard: View {
    let tile: VoiceTile
    @ObservedObject var viewModel: TTSViewModel

    private var isPlaying: Bool { viewModel.previewingVoiceID == tile.name }

    var body: some View {
        VStack(spacing: 24) {
            animatedCoverArt
                .padding(.top, 24)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(tile.displayName)
                        .font(.title3)
                        .bold()
                        .foregroundStyle(Color.appPrimaryText)
                    Text(tile.countryFlag)
                        .font(.title3)
                }
                Text(tile.longDescription)
                    .font(.subheadline)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
            }

            // The "track" — playback progress for the current clip. Gated on
            // isPlaying: previewProgress is one shared value on the view
            // model, so a neighbouring card would otherwise show the
            // *playing* voice's progress on a card that isn't playing.
            ProgressView(value: isPlaying ? viewModel.previewProgress : 0)
                .tint(Color.appPrimaryText)
                .padding(.horizontal, 40)

            Button {
                viewModel.togglePreview(voiceName: tile.name, engine: tile.engine)
            } label: {
                LucideIcon(isPlaying ? .circlePause : .circlePlay, size: 64, color: Color.appPrimaryText)
            }
            .disabled(!tile.isAvailable)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var coverArt: some View {
        Image(VoiceCoverArt.assetName(for: tile.name))
            .resizable()
            .scaledToFill()
    }

    /// This card's own cover art, blown up to fill it at low opacity
    /// (blurred + scrimmed so the foreground text/controls stay legible over
    /// any cover) — the same ambient-art treatment Music/Podcasts-style
    /// players use behind their now-playing screen.
    private var cardBackground: some View {
        ZStack {
            Color.appBackground
            coverArt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 30)
                .opacity(0.4)
            Color.appBackground.opacity(0.55)
        }
    }

    // Layers the BlobShape deformation on top of the existing scale/opacity
    // pulse. The per-frame TimelineView only runs while actually playing —
    // at rest this renders a plain, static BlobShape(amplitude: 0), which is
    // exactly a circle, with no continuous timer burning CPU in the
    // background.
    @ViewBuilder
    private var animatedCoverArt: some View {
        if isPlaying {
            TimelineView(.animation) { timeline in
                blobClippedCoverArt(phase: phase(at: timeline.date))
            }
        } else {
            blobClippedCoverArt(phase: 0)
        }
    }

    private func blobClippedCoverArt(phase: CGFloat) -> some View {
        coverArt
            .frame(width: 180, height: 180)
            .clipShape(BlobShape(amplitude: isPlaying ? viewModel.previewLevel : 0, phase: phase))
            .scaleEffect(isPlaying ? 1 + viewModel.previewLevel * 0.12 : 1)
            .opacity(isPlaying ? 0.85 + viewModel.previewLevel * 0.15 : 1)
            .animation(.easeInOut(duration: 0.12), value: viewModel.previewLevel)
    }

    // Radians/sec — slow, organic drift rather than a visible spin.
    private let blobRotationSpeed: Double = 1.4

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate * blobRotationSpeed)
    }
}

#Preview {
    let tiles = [
        VoiceTile(
            id: "kokoro-af_heart", name: "af_heart", engine: .kokoroAne, engineLabel: "Kokoro-ANE",
            isAvailable: true),
        VoiceTile(
            id: "kokoro-af_alloy", name: "af_alloy", engine: .kokoroAne, engineLabel: "Kokoro-ANE",
            isAvailable: true),
    ]
    VoicePreviewSheet(
        tiles: tiles, initialTileID: tiles[0].id,
        viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
