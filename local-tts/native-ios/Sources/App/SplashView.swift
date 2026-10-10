import SwiftUI

/// The app's opening wordmark: the same paper surface About uses, with
/// "Minimalist Reader" drawn as a left-to-right ink reveal.
///
/// Deliberately **not** a gate in front of `RootTabView` — the app root stays
/// mounted underneath (see `KokoroAneTestApp`), so the shelf's own `.task`
/// work runs while this is still on screen and the moment the splash clears
/// is a warm frame rather than a spinner.
///
/// It owns its whole choreography, including its own fade-out, rather than
/// the app root running a timer and animating the removal. Two reasons: how
/// long the ink takes is this view's business, and **a removal animated by
/// the caller could not be relied on** — the caller's `isSplashVisible` lives
/// on the `App` struct, where a `.transition` driven by `withAnimation` does
/// not reliably animate. Fading `opacity` here and only *then* calling
/// `onFinished` means the view is already invisible when it is removed, so
/// the dismissal looks the same however the caller takes it out of the tree.
struct SplashView: View {
    /// Called once the wordmark has drawn, held, and faded fully out. The
    /// caller just removes the view — there is nothing left to animate.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRevealed = false
    @State private var opacity: Double = 1

    /// Slower than `SignatureText`'s 1.15s default, and slower than About's
    /// use of it: there the signature is one element among several in a
    /// staggered entrance, while here it is the only thing on screen and is
    /// what the launch is actually for.
    private let inkDuration: TimeInterval = 2.0
    /// A beat after the last glyph fills, so the finished wordmark reads as a
    /// wordmark rather than being swept away the instant it completes.
    private let holdAfterInk: TimeInterval = 0.4
    private let fadeDuration: TimeInterval = 0.55
    /// Reduce Motion gets no reveal to wait on — `SignatureText` draws itself
    /// complete immediately — so this is the whole of its on-screen time
    /// before the fade.
    private let reducedMotionHold: TimeInterval = 0.7

    var body: some View {
        ZStack {
            TexturedLightBackground()
                .ignoresSafeArea()

            SignatureText(
                "Minimalist Reader",
                isRevealed: isRevealed,
                color: BookShelfPalette.primaryText,
                fontSize: 38,
                duration: inkDuration,
                isHeading: true)
                // The frame, not `fontSize`, is what sets the rendered size:
                // `SignatureText` scales its cached glyph art to fit whatever
                // box it is given. `maxWidth` plus real side padding so the
                // wordmark never reaches the edges on a small phone.
                .frame(maxWidth: 330)
                .padding(.horizontal, 28)
        }
        .opacity(opacity)
        // Deliberately no `.preferredColorScheme(.light)`, unlike About's own
        // use of this surface. Every colour here is a fixed value rather than
        // a semantic one, so the splash looks identical either way — and
        // forcing a scheme would hand the *window* a scheme change at the
        // exact moment the splash is clearing, which is the one moment that
        // has to look seamless.
        .task {
            if reduceMotion {
                try? await Task.sleep(for: .seconds(reducedMotionHold))
            } else {
                // One beat before the ink starts, so the reveal is seen
                // beginning rather than already underway on the first
                // rendered frame — the same settle About's entrance uses.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isRevealed = true
                try? await Task.sleep(for: .seconds(inkDuration + holdAfterInk))
            }
            guard !Task.isCancelled else { return }
            // A cross-fade stays appropriate under Reduce Motion — it is the
            // substitute for motion, not an instance of it.
            withAnimation(.easeInOut(duration: fadeDuration)) { opacity = 0 }
            try? await Task.sleep(for: .seconds(fadeDuration))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}

#Preview {
    SplashView(onFinished: {})
}
