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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isPressed = false

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
        // Apply glass to the hit-tested surface itself. Putting interactive
        // glass on a `Color.clear` background child leaves that child outside
        // the gesture's interaction path, so it renders correctly but never
        // receives Liquid Glass's pressed response.
        .modifier(MiniPlayerGlassSurface())
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .contentShape(Capsule())
        // This restrained transform makes the response legible on every OS;
        // iOS 26 adds its native fluid highlight on top, while older systems
        // use the material's brighter pressed state.
        .scaleEffect(pressScale)
        .brightness(pressBrightness)
        .animation(pressAnimation, value: isPressed)
        .simultaneousGesture(pressGesture)
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing, \(player.bookTitle)")
        .accessibilityHint("Opens the full playback screen")
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, pressed, _ in
                pressed = true
            }
    }

    private var pressScale: CGFloat {
        guard !reduceMotion else { return 1 }
        return isPressed ? 0.985 : 1
    }

    private var pressBrightness: Double {
        guard isPressed else { return 0 }
        if #available(iOS 26.0, *) { return 0.035 }
        return 0.07
    }

    private var pressAnimation: Animation? {
        return reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.24, dampingFraction: 0.72)
    }
}

/// Clear interactive Liquid Glass on iOS 26; a transparent material capsule
/// on the app's iOS 18 deployment target. The modifier belongs on the player
/// content—not a background child—so Liquid Glass shares the bar's hit path.
private struct MiniPlayerGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear.interactive(), in: Capsule())
                .overlay { border }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { border }
        }
    }

    private var border: some View {
        Capsule().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.75)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return MiniPlayerBar(player: app.player, onExpand: {})
        .padding(.horizontal, 19)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color.whitePaper)
}
