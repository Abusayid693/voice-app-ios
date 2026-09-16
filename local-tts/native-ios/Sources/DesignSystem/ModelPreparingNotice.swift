import SwiftUI

/// The "Initializing model…" notice shown during an engine's one-time
/// cold-start load (issue #4). Deliberately **not** auto-dismissing: it
/// stays until preparation finishes or the user taps it, since the whole
/// point is explaining a wait whose length we can't predict (there's no
/// progress callback for `initialize()` — only an indeterminate spinner).
///
/// Non-blocking: it floats over the screen without a scrim, so the page
/// underneath stays usable while the model loads.
private struct ModelPreparingNotice: View {
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Initializing model…").appText(.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Floats `ModelPreparingNotice` above this view in screen space.
    ///
    /// Apply to a whole `NavigationStack`, not to content inside one: an
    /// overlay placed inside is positioned against the stack's content
    /// area, which shifts as a large title collapses (see ImportHomeView's
    /// `body` comment for the same trap). Hosting it outside also keeps
    /// the notice on screen across a push — which the Kokoro path needs,
    /// since tapping Generate navigates to the read-along screen before
    /// the slow load even starts.
    func modelPreparingNotice(isPresented: Bool, onDismiss: @escaping () -> Void) -> some View {
        ZStack(alignment: .top) {
            self

            if isPresented {
                ModelPreparingNotice(onDismiss: onDismiss)
                    // Clears the nav bar, same offset the Setup pointer uses.
                    .padding(.top, 50)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}
