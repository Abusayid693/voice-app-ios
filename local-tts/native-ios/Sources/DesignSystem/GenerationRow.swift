import Hugeicons
import LucideSwift
import SwiftUI

/// One saved generation's row — an engine-icon avatar, its text, and a
/// trailing play icon (decorative; the whole row is the real tap target,
/// same as before). A cross-feature component, not a token, but lives
/// here anyway since `Features/Library/` and Import's Projects row both
/// need the exact same row and previously duplicated it with slightly
/// different content (Import's own version stacked a 3rd "Updated …"
/// line instead of combining the voice/date into one subtitle line, the
/// way Library already did) — now both read the same two fields, matching
/// Library's shape.
struct GenerationRow: View {
    let icon: LucideIconName
    var iconStyle: LucideIconStyle = .stroked
    var coverURL: URL?
    let title: String
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let coverURL {
                SavedProjectCover(
                    coverURL: coverURL, title: title,
                    size: CGSize(width: 44, height: 66))
            } else {
                fallbackIcon
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.rowTitle)
                    .lineLimit(1)
                Text(subtitle).appText(.label)
            }

            Spacer()

            Hugeicons.play.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 22, height: 22)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var fallbackIcon: some View {
        Circle()
            .fill(Color.appSecondaryBackground)
            .frame(width: 40, height: 40)
            .overlay {
                LucideIcon(icon, style: iconStyle, size: 16, color: Color.appPrimaryText)
            }
    }
}
