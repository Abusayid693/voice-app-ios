import SwiftUI

/// The Apple-Music-style floating bar for music mode — cover thumbnail,
/// book title, "Page N of M", and a play/pause button, stacked above
/// `CustomTabBar` in `RootTabView`'s own bottom safe-area inset so both
/// share one layout pass and one visibility clock (see
/// `NavigationChromeVisibility`'s own doc comment on why two independent
/// clocks was a bug worth not repeating). Persists across every pushed
/// screen except the reader, which has its own floating transport.
struct MiniPlayerBar: View {
    @ObservedObject var player: BookAudioPlayer
    let onExpand: () -> Void

    private let barHeight: CGFloat = 60

    var body: some View {
        HStack(spacing: 12) {
            SavedProjectCover(
                coverURL: player.coverURL, title: player.bookTitle,
                size: CGSize(width: 36, height: 36), cornerRadius: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.bookTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let ref = player.activeRef {
                    Text("Page \(ref.pageIndex + 1) of \(player.pageCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            PlayPauseBounceButton(
                isPlaying: player.isPlaying, tapTargetSize: 40, action: player.togglePlayPause
            ) { isPlaying in
                // Same SF Symbol pair as NowPlayingView's own play/pause —
                // one glyph language across both surfaces rather than this
                // bar's shrinking down to a different icon set.
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: barHeight)
        .background { barBackground }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .contentShape(Capsule())
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing, \(player.bookTitle)")
        .accessibilityHint("Opens the full playback screen")
    }

    /// Clear Liquid Glass on iOS 26+ — untinted, so the shelf reads through
    /// it — with `.ultraThinMaterial` as the pre-26 stand-in. Both are
    /// transparent, which is why nothing in this bar uses the app's fixed
    /// `appPrimaryText`: it floats over the *light* Book Shelf and over
    /// *dark* pushed screens (Library, Voices, Tools), so its foreground has
    /// to follow the environment's scheme instead. `ImportHomeView` already
    /// flips `.preferredColorScheme` per route, so `Color.primary` resolves
    /// correctly on both.
    /// `.clear` rather than `.regular`, matching `GlassBookShelf`'s own
    /// glass on the same screen — `.regular` is the frosted variant and
    /// reads as a solid light fill over the pale shelf. Below iOS 26 there
    /// is no real Liquid Glass, and `.ultraThinMaterial` is the closest
    /// stand-in this app already uses everywhere else; it is genuinely
    /// frostier than the real thing, which is visible on the deployment
    /// target (18.0) but not on 26.
    @ViewBuilder
    private var barBackground: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.75)
        }
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return MiniPlayerBar(player: app.bookPlayer, onExpand: {})
        .padding(.horizontal, 19)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color.whitePaper)
}
