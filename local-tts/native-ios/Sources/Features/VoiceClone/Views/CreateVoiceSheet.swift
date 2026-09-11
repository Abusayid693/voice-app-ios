import SwiftUI

/// Bottom sheet reached from the Voices tab's "+ New voice"/toolbar "+"
/// and Import's "Create your own voice" row — offers Instant Clone or
/// Upload file, each a real push within this sheet's own NavigationStack
/// (so it behaves the same regardless of which tab presented it, and a
/// pushed screen's own `dismiss()` only pops here rather than closing the
/// whole sheet — that's why InstantCloneView/UploadVoiceView call
/// `onFinished` instead, for the presenter to close the sheet itself).
struct CreateVoiceSheet: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    let onFinished: () -> Void
    @State private var path: [VoiceCloneRoute] = []
    @State private var detentSelection: PresentationDetent = .medium

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                optionRow(
                    title: "Instant Clone", subtitle: "Record a short sample now",
                    systemImage: "mic.fill"
                ) {
                    path.append(.instantClone)
                }
                optionRow(
                    title: "Upload file", subtitle: "Use an existing recording",
                    systemImage: "square.and.arrow.up"
                ) {
                    path.append(.upload)
                }
                Spacer()
            }
            .padding()
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Create Voice")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VoiceCloneRoute.self) { route in
                switch route {
                case .instantClone:
                    InstantCloneView(viewModel: viewModel, onFinished: onFinished)
                case .upload:
                    UploadVoiceView(viewModel: viewModel, onFinished: onFinished)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $detentSelection)
        .onAppear { viewModel.discardRecording() }
        .onChange(of: path) { _, newValue in
            detentSelection = newValue.isEmpty ? .medium : .large
        }
    }

    private func optionRow(
        title: String, subtitle: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                    Text(subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.appTertiaryText)
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
            CreateVoiceSheet(
                viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()), onFinished: {})
        }
}
