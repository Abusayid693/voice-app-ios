import SwiftUI

/// Shared card typography — same font size/weight/color everywhere a card
/// shows a title + short description (Trending voices' `VoiceTileView`,
/// Import's `ReadAnythingCard`, and any future card that wants the same
/// look). Callers still apply their own `.lineLimit`/`.truncationMode`/etc.
/// on top, since those vary per card; only the type style is standardized.
struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.appPrimaryText)
    }
}

struct CardDesc: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.appTertiaryText)
    }
}
