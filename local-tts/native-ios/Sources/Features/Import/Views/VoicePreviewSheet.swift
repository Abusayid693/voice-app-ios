import LucideSwift
import SwiftUI

/// Half-height sheet reached by tapping a voice in VoicesTabView's grid (or
/// a row in the reader's Voice Library) — presented as a horizontally
/// scrolling carousel of *whole sheet cards*, one per voice, with the
/// neighbouring voices' cards peeking in at both edges.
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
    // Not observed here — each card observes it, so a meter tick doesn't
    // re-evaluate the whole carousel.
    let previewPlayer: VoicePreviewPlayer
    let onUseVoice: ((VoiceTile) -> Void)?

    @State private var currentTileID: String?
    @Environment(\.dismiss) private var dismiss

    /// Horizontal inset on each side of the focused card. The neighbouring
    /// card peeks in by `cardPeek - cardSpacing`, so these two together set
    /// how much of the next voice is visible at rest.
    private let cardPeek: CGFloat = 28
    private let cardSpacing: CGFloat = 12

    init(
        tiles: [VoiceTile],
        initialTileID: String,
        previewPlayer: VoicePreviewPlayer,
        onUseVoice: ((VoiceTile) -> Void)? = nil
    ) {
        self.tiles = tiles
        self.initialTileID = initialTileID
        self.previewPlayer = previewPlayer
        self.onUseVoice = onUseVoice
        _currentTileID = State(initialValue: initialTileID)
    }

    var body: some View {
        Group {
            if let tile = tiles.first, tiles.count == 1 {
                VoicePreviewCard(
                    tile: tile,
                    previewPlayer: previewPlayer,
                    onUseVoice: onUseVoice.map { action in
                        { action(tile); dismiss() }
                    })
                    .padding(.horizontal, cardPeek)
            } else {
                carousel
            }
        }
        .padding(.vertical, 16)
        .presentationDetents(onUseVoice == nil ? [.medium] : [.height(620)])
        .presentationDragIndicator(.visible)
        // Hides the system sheet's own card so ours are the only ones on
        // screen — see the type's doc comment.
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        // Scrolling to another voice always stops whatever was playing — its
        // audio would otherwise keep going under a different voice's card.
        // Doesn't auto-start the new one; matches today's tap-to-play.
        .onChange(of: currentTileID) { _, _ in
            previewPlayer.stop()
        }
        .onDisappear {
            previewPlayer.stop()
        }
    }

    private var carousel: some View {
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
                            VoicePreviewCard(tile: tile, previewPlayer: previewPlayer, onUseVoice: nil)
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
    }
}

/// One voice's sheet card: ambient blurred cover backdrop, cover art
/// (blob-deformed while playing), name/engine label, progress track and
/// play button — the whole thing rounded and clipped so it reads as its own
/// sheet rather than content inside a shared one.
private struct VoicePreviewCard: View {
    let tile: VoiceTile
    @ObservedObject var previewPlayer: VoicePreviewPlayer
    let onUseVoice: (() -> Void)?

    private var isPlaying: Bool { previewPlayer.playingVoiceID == tile.name }
    // Preview playback is pure bundled-file playback, independent of
    // whether the voice's pack has been downloaded — gating the button on
    // `tile.isAvailable` (pack-download state) made every voice whose pack
    // isn't downloaded yet unplayable even when it has a real clip (this is
    // exactly why Mandarin previews silently did nothing before any
    // Mandarin pack was downloaded). Gate on clip existence instead.
    private var hasPreview: Bool { previewPlayer.hasClip(voiceName: tile.name, engine: tile.engine) }

    var body: some View {
        VStack(spacing: 24) {
            animatedCoverArt
                .padding(.top, 24)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(tile.displayName)
                        .appText(.title)
                    // Deliberately uncolored — the emoji renders its own
                    // full-color glyph regardless.
                    Text(tile.countryFlag)
                        .font(AppTextStyle.title.font)
                }
                Text(tile.longDescription)
                    .appText(.body)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
            }

            // The "track" — playback progress for the current clip. Gated on
            // isPlaying: progress is one shared value on the player, so a
            // neighbouring card would otherwise show the *playing* voice's
            // progress on a card that isn't playing.
            ProgressView(value: isPlaying ? previewPlayer.progress : 0)
                .tint(Color.appPrimaryText)
                .padding(.horizontal, 40)

            Button {
                previewPlayer.toggle(voiceName: tile.name, engine: tile.engine)
            } label: {
                LucideIcon(isPlaying ? .circlePause : .circlePlay, size: 64, color: Color.appPrimaryText)
            }
            .disabled(!hasPreview)
            .opacity(hasPreview ? 1 : 0.6)

            if !hasPreview {
                Text("Preview coming soon")
                    .appText(.meta)
            }

            if let onUseVoice {
                Button("Use Voice", action: onUseVoice)
                    .buttonStyle(.primary)
                    .padding(.horizontal, 32)
            }

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
            .clipShape(BlobShape(amplitude: isPlaying ? previewPlayer.level : 0, phase: phase))
            .scaleEffect(isPlaying ? 1 + previewPlayer.level * 0.12 : 1)
            .opacity(isPlaying ? 0.85 + previewPlayer.level * 0.15 : 1)
            .animation(.easeInOut(duration: 0.12), value: previewPlayer.level)
    }

    // Radians/sec — slow, organic drift rather than a visible spin.
    private let blobRotationSpeed: Double = 1.4

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate * blobRotationSpeed)
    }
}

#Preview {
    let tiles = VoiceCatalog.kokoroEnglish.prefix(2).map { voice in
        VoiceTile(
            id: "kokoro-english-\(voice.code)", voice: voice, engine: .kokoroAne,
            engineLabel: "Kokoro-ANE", isAvailable: true)
    }
    VoicePreviewSheet(
        tiles: tiles, initialTileID: tiles[0].id, previewPlayer: VoicePreviewPlayer())
}
