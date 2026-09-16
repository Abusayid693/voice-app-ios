import LucideSwift
import SwiftUI

/// Minimal stand-in for a tab that has no real screen yet (Explore,
/// Library, Voices) — reused rather than one near-identical file per tab.
struct PlaceholderTabView: View {
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                LucideIcon(.hourglass, size: 34)
                    .foregroundStyle(.secondary)
                Text("\(title) coming soon")
                    .font(AppTextStyle.sectionTitle.font)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(title)
        }
    }
}

#Preview {
    PlaceholderTabView(title: "Explore")
}
