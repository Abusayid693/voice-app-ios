import LucideSwift
import SwiftUI

/// The 8 quick actions reachable from the floating "+" button (any tab) —
/// the exact same actions/icons as `ImportHomeView`'s two action grids
/// ("Listen to text"/"Make audio"), just presented as a picker rather than
/// inline tiles. Not `private` — `RootTabView` needs to distinguish
/// `.writeText` from the other 7 to decide what happens next.
enum QuickAction: CaseIterable, Identifiable {
    case pasteLink, uploadFile, scanText, writeText
    case cloneVoice, uploadBook, createPodcast, changeVoice

    var id: Self { self }

    var title: String {
        switch self {
        case .pasteLink: return "Paste a link"
        case .uploadFile: return "Upload a file"
        case .scanText: return "Scan text"
        case .writeText: return "Write text"
        case .cloneVoice: return "Clone voice"
        case .uploadBook: return "Upload Book"
        case .createPodcast: return "Create Podcast"
        case .changeVoice: return "Change Voice"
        }
    }

    var icon: LucideIconName {
        switch self {
        case .pasteLink: return .link
        case .uploadFile: return .file
        case .scanText: return .scan
        case .writeText: return .textCursor
        case .cloneVoice: return .mic
        case .uploadBook: return .bookUp
        case .createPodcast: return .radio
        case .changeVoice: return .repeatIcon
        }
    }
}

/// Bottom sheet reached from `RootTabView`'s floating "+" button. Like
/// `CreateVoiceSheet`, this doesn't act itself — it reports the choice up
/// via `onSelect` and lets the presenter decide what happens (including
/// dismissing this sheet). Only `.writeText` does anything today; the
/// other 7 are listed for completeness, same status as their equivalent
/// tiles on Home.
struct QuickActionsSheet: View {
    let onSelect: (QuickAction) -> Void

    private static let listenActions: [QuickAction] = [.pasteLink, .uploadFile, .scanText, .writeText]
    private static let makeActions: [QuickAction] = [.cloneVoice, .uploadBook, .createPodcast, .changeVoice]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(title: "Listen to text", actions: Self.listenActions)
                section(title: "Make audio", actions: Self.makeActions)
            }
            .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func section(title: String, actions: [QuickAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appText(.sectionTitle)
            ForEach(actions) { action in
                row(for: action)
            }
        }
    }

    private func row(for action: QuickAction) -> some View {
        Button {
            onSelect(action)
        } label: {
            HStack(spacing: 12) {
                LucideIcon(action.icon, size: 22, color: Color.appPrimaryText)
                    .frame(width: 32)
                Text(action.title).appText(.rowTitle)
                Spacer()
                LucideIcon(.chevronRight, color: Color.appTertiaryText)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Text("Host")
        .sheet(isPresented: .constant(true)) {
            QuickActionsSheet { _ in }
        }
}
