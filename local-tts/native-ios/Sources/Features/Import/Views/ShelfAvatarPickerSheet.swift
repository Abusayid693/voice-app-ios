import LucideSwift
import SwiftUI

/// Home's navigation-bar looping avatar clip (Reading mode, trailing) —
/// several bundled options the reader can pick between, not tied to any
/// voice/engine. Selection persists via @AppStorage on ImportHomeView.
enum ShelfAvatar: String, CaseIterable, Identifiable {
    case first
    case second
    case third
    case fourth

    var id: String { rawValue }

    private var resourceName: String {
        switch self {
        case .first: "shelf-avatar-loop"
        case .second: "shelf-avatar-loop-2"
        case .third: "shelf-avatar-loop-3"
        case .fourth: "shelf-avatar-loop-4"
        }
    }

    var displayName: String {
        switch self {
        case .first: "Avatar 1"
        case .second: "Avatar 2"
        case .third: "Avatar 3"
        case .fourth: "Avatar 4"
        }
    }

    var videoURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mp4")
    }
}

/// Reached by tapping ImportHomeView's navigation-bar looping avatar clip
/// (Reading mode) — a plain list of the bundled avatar options, each with
/// its own live looping preview. Styled after BookShelfPalette's light
/// surface (not the app's global dark sheet palette CreateVoiceSheet uses),
/// since this is reached from within Home's Reading mode, not Import/VoiceClone.
struct ShelfAvatarPickerSheet: View {
    @Binding var selection: ShelfAvatar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose Avatar")
                .font(.custom("Didot-Bold", size: 22, relativeTo: .title2))
                .foregroundStyle(BookShelfPalette.primaryText)
                .padding(.top, 8)

            VStack(spacing: 10) {
                ForEach(ShelfAvatar.allCases) { avatar in
                    avatarRow(avatar)
                }
            }

            Spacer()
        }
        .padding()
        .background(BookShelfPalette.background.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func avatarRow(_ avatar: ShelfAvatar) -> some View {
        Button {
            selection = avatar
            dismiss()
        } label: {
            HStack(spacing: 12) {
                avatarThumbnail(avatar)

                Text(avatar.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BookShelfPalette.primaryText)

                Spacer()

                if selection == avatar {
                    LucideIcon(.check, size: 18, color: BookShelfPalette.primaryText)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(avatar.displayName)
        .accessibilityAddTraits(selection == avatar ? [.isSelected] : [])
    }

    @ViewBuilder
    private func avatarThumbnail(_ avatar: ShelfAvatar) -> some View {
        // .third's source recording is wider (1282x1104, not square like
        // the others), so its thumbnail gets 5pt more width on each side
        // rather than being cropped as tightly by .resizeAspectFill.
        let width: CGFloat = avatar == .third ? 54 : (avatar == .second ? 61.6 : 44)
        let height: CGFloat = avatar == .second ? 61.6 : 44
        if let url = avatar.videoURL {
            LoopingVideoPlayerView(url: url)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.06))
                .frame(width: width, height: height)
        }
    }
}

#Preview {
    Text("Host")
        .sheet(isPresented: .constant(true)) {
            ShelfAvatarPickerSheet(selection: .constant(.first))
        }
}
