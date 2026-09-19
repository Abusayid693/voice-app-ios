import SwiftUI

/// The "Initializing model…" notice (issue #4) — shown on the leading
/// side of WriteTextView's own toolbar (its close button sits on the
/// trailing side) while an engine runs its one-time cold-start load.
/// Deliberately **not** auto-dismissing: it stays until preparation
/// finishes or the user taps it, since the whole point is explaining a
/// wait whose length we can't predict (there's no progress callback for
/// `initialize()` — only an indeterminate spinner). Plain text, no
/// card/border/background — it reads as part of the page, not a popup.
struct ModelPreparingNotice: View {
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 10) {
                // .px20 is the tuned small-size preset (dot count/speed
                // fitted for compact use, unlike .px64's showcase design);
                // displaySize renders it at this notice's actual 30pt
                // without changing that geometry — see ThinkingOrb's own
                // doc comment.
                ThinkingOrb(state: .searching, size: .px20, displaySize: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Initializing model…").appText(.label)
                    Text("One-time process").appText(.meta)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
