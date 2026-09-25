import LucideSwift
import SwiftUI

/// Minimal stand-in for an Explore destination that has no real screen yet
/// (currently Tools). Pushed onto Home's stack, so it brings no navigation
/// container of its own — the type name is historical.
struct PlaceholderTabView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            LucideIcon(.hourglass, size: 34, color: Color.appSecondaryText)
            Text("\(title) coming soon")
                .font(AppTextStyle.sectionTitle.font)
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(title)
    }
}

#Preview {
    NavigationStack {
        PlaceholderTabView(title: "Tools")
    }
    .preferredColorScheme(.dark)
}
