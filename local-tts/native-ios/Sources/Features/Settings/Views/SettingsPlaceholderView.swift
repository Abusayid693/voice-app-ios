import SwiftUI

/// Minimal stand-in for a Settings section that has no real content yet
/// (Voice Packs / Storage / About — see issue #9). A push destination, not
/// a tab root, so it doesn't wrap its own NavigationStack.
struct SettingsPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Text("\(title) coming soon")
                .font(.headline)
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsPlaceholderView(title: "Voice Packs")
    }
}
