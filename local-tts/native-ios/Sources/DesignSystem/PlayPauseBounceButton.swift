import SwiftUI

/// The bounce every play/pause control in this app uses on a state change:
/// scale down, swap the icon at the compressed midpoint (never cross-fading
/// the two assets — a play glyph and a pause glyph don't share enough shape
/// for a cross-fade to read as one object changing state), spring back.
/// Skipped under Reduce Motion, where the icon just swaps immediately.
///
/// Originally `ChapterPlayerView`'s own `animatePlayPauseIcon`, promoted
/// here once `BookAudioPlayer`'s two transport surfaces (`NowPlayingView`,
/// `MiniPlayerBar`) needed the identical motion — one shared curve/timing so
/// every transport in the app moves the same way; only the icon and tap
/// target size vary per call site, supplied as a closure so this stays
/// independent of any one icon set (call sites here mix Hugeicons and SF
/// Symbols).
///
/// A caller that needs a **hard reset** — snap to the current state with no
/// bounce, e.g. because the page or voice just changed and a page change is
/// already its own transition — should apply `.id(_:)` with a value that
/// changes exactly when that reset should happen. `.id(_:)` forces SwiftUI
/// to discard and recreate this view's `@State` from scratch, which
/// reinitializes `displayedIsPlaying` from whatever `isPlaying` reads at
/// that moment with no animation of its own — the same mechanism any
/// `@State`-holding view uses to reset on an identity change, so no extra
/// API is needed on this type for it.
struct PlayPauseBounceButton<Icon: View>: View {
    let isPlaying: Bool
    var tapTargetSize: CGFloat = 64
    let action: () -> Void
    @ViewBuilder let icon: (_ isPlaying: Bool) -> Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedIsPlaying: Bool
    @State private var scale: CGFloat = 1
    @State private var animationTask: Task<Void, Never>?

    init(
        isPlaying: Bool, tapTargetSize: CGFloat = 64, action: @escaping () -> Void,
        @ViewBuilder icon: @escaping (_ isPlaying: Bool) -> Icon
    ) {
        self.isPlaying = isPlaying
        self.tapTargetSize = tapTargetSize
        self.action = action
        self.icon = icon
        _displayedIsPlaying = State(initialValue: isPlaying)
    }

    var body: some View {
        Button(action: action) {
            icon(displayedIsPlaying)
                .contentTransition(.identity)
                .scaleEffect(scale)
                .frame(width: tapTargetSize, height: tapTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: isPlaying) { _, newValue in animate(to: newValue) }
    }

    private func animate(to newValue: Bool) {
        animationTask?.cancel()
        guard !reduceMotion else {
            displayedIsPlaying = newValue
            scale = 1
            return
        }

        withAnimation(.easeIn(duration: 0.09)) {
            scale = 0.76
        }
        animationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            // Swapped without animation at the compressed midpoint so the
            // two icon assets never cross-fade through one another.
            displayedIsPlaying = newValue
            withAnimation(.spring(response: 0.32, dampingFraction: 0.52)) {
                scale = 1
            }
        }
    }
}
