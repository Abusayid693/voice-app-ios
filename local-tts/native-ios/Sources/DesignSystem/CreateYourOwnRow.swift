import Hugeicons
import SwiftUI

/// The "Create your own voice"/"Create your own book" entry-point row on
/// Import's Home page — icon, title, one-line subtitle, tap to act.
/// Extracted since both rows were the exact same layout, differing only
/// in icon/copy/action.
struct CreateYourOwnRow: View {
    let icon: HugeiconsAsset
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.image()
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appText(.rowTitle)
                    Text(subtitle).appText(.label)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
