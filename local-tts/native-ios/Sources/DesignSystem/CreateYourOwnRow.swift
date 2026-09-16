import LucideSwift
import SwiftUI

/// The "Create your own voice"/"Create your own book" entry-point row on
/// Import's Home page — icon, title, one-line subtitle, tap to act.
/// Extracted since both rows were the exact same layout, differing only
/// in icon/copy/action.
struct CreateYourOwnRow: View {
    let icon: LucideIconName
    var iconStyle: LucideIconStyle = .stroked
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LucideIcon(icon, style: iconStyle, size: 28, color: Color.appPrimaryText)
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
