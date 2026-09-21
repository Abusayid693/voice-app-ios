import SwiftUI

/// The ⋯ menu reached from `ChapterPlayerView`'s nav bar — two persisted
/// preferences (both `@AppStorage`, owned by the presenter, passed down as
/// `Binding`s so this sheet has no storage of its own to fall out of sync
/// with). Small (`.medium` only — QuickActionsSheet's `[.medium, .large]`
/// would leave a lot of dead space below two rows).
///
/// First `Toggle` usage in this codebase — `.tint(Color.appPrimaryText)`
/// matches the tint the scrubber `Slider` already uses, rather than
/// SwiftUI's default system green.
struct ChapterPlayerOptionsSheet: View {
    @Binding var keepScreenOn: Bool
    @Binding var showFloatingPlayer: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                row(
                    title: "Keep screen on",
                    subtitle: "Prevents the screen from auto-locking on this page",
                    isOn: $keepScreenOn)
                row(
                    title: "Floating player",
                    subtitle: "Show the playback controls floating over the text",
                    isOn: $showFloatingPlayer)
            }
            .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func row(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.rowTitle)
                Text(subtitle).appText(.label)
            }
        }
        .tint(Color.appPrimaryText)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }
}

#Preview {
    Text("Host")
        .sheet(isPresented: .constant(true)) {
            ChapterPlayerOptionsSheet(keepScreenOn: .constant(false), showFloatingPlayer: .constant(true))
        }
}
