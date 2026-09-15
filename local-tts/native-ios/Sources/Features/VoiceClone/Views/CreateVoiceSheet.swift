import LucideSwift
import SwiftUI

/// Bottom sheet reached from the Voices tab's "+ New voice"/toolbar "+"
/// and Import's "Create your own voice" row — a pure chooser between
/// Instant Clone and Upload file. It does not navigate itself: picking an
/// option reports the choice up via `onSelect`, and the presenter (which
/// owns the real NavigationStack) dismisses this sheet and pushes the
/// chosen screen as a real page — see VoicesTabView/ImportHomeView.
struct CreateVoiceSheet: View {
    let onSelect: (VoiceCloneRoute) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Voice")
                .appText(.sectionTitle)
                .padding(.top, 8)

            optionRow(
                title: "Instant Clone", subtitle: "Record a short sample now",
                icon: .mic
            ) {
                onSelect(.instantClone)
            }
            optionRow(
                title: "Upload file", subtitle: "Use an existing recording",
                icon: .upload
            ) {
                onSelect(.upload)
            }

            Spacer()
        }
        .padding()
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func optionRow(
        title: String, subtitle: String, icon: LucideIconName, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LucideIcon(icon, size: 22, color: Color.appPrimaryText)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appText(.rowTitle)
                    Text(subtitle).appText(.label)
                }
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
            CreateVoiceSheet { _ in }
        }
}
