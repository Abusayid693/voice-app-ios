import LucideSwift
import SwiftUI

/// The Voices tab: manage cloned voices — create new ones, preview or
/// delete existing ones. Selecting one for actual generation happens from
/// VoiceSettingsSheet's "My Voices" section, not here.
struct VoicesTabView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    @State private var isCreateVoicePresented = false
    @State private var voiceCloneRoute: VoiceCloneRoute?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.clonedVoices.isEmpty {
                    emptyState
                } else {
                    List {
                        Section("Clone voices") {
                            cloneVoicesStrip
                        }
                        .listRowBackground(Color.appBackground)
                        .listRowInsets(EdgeInsets())

                        Section("Your voices") {
                            ForEach(viewModel.clonedVoices) { voice in
                                row(for: voice)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    viewModel.deleteVoice(viewModel.clonedVoices[index])
                                }
                            }
                        }
                        .listRowBackground(Color.appSecondaryBackground)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Voices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isCreateVoicePresented = true
                    } label: {
                        LucideIcon(.plus)
                    }
                }
            }
            .navigationDestination(item: $voiceCloneRoute) { route in
                switch route {
                case .instantClone:
                    InstantCloneView(viewModel: viewModel) { voiceCloneRoute = nil }
                case .upload:
                    UploadVoiceView(viewModel: viewModel) { voiceCloneRoute = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isCreateVoicePresented) {
            CreateVoiceSheet { route in
                isCreateVoicePresented = false
                voiceCloneRoute = route
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.mic, size: 48, color: Color.appSecondaryText)
            Text("No cloned voices yet")
                .foregroundStyle(Color.appSecondaryText)
            Button("Create your own voice") { isCreateVoicePresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Quick horizontal access — every cloned voice plus a trailing add
    // button, alongside the full list below ("Your voices" — recents-strip
    // + full-list pattern; some duplication is intentional).
    private var cloneVoicesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(viewModel.clonedVoices) { voice in
                    Button {
                        viewModel.togglePreview(for: voice)
                    } label: {
                        VStack(spacing: 6) {
                            avatar(for: voice, size: 56)
                            Text(voice.name)
                                .font(.caption)
                                .foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isCreateVoicePresented = true
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .strokeBorder(Color.appSecondaryText, style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: 56, height: 56)
                            .overlay {
                                LucideIcon(.plus, color: Color.appSecondaryText)
                            }
                        Text("New voice")
                            .font(.caption)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    .frame(width: 72)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func row(for voice: ClonedVoice) -> some View {
        HStack(spacing: 12) {
            avatar(for: voice, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .foregroundStyle(Color.appPrimaryText)
                Text("\(voice.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(voice.language.displayName)")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }

            Spacer()

            Button {
                viewModel.togglePreview(for: voice)
            } label: {
                if viewModel.previewingVoiceID == voice.id && viewModel.isPreviewLoading {
                    ProgressView()
                } else {
                    LucideIcon(
                        viewModel.previewingVoiceID == voice.id ? .circlePause : .circlePlay,
                        size: 22, color: Color.appPrimaryText)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // Seeded by `voice.id` rather than `voice.name` — the name is
    // user-editable (rename), and keying off it would make a voice's orb
    // change after a rename; `id` is stable for the voice's whole lifetime.
    private func avatar(for voice: ClonedVoice, size: CGFloat) -> some View {
        Image(OrbCoverArt.assetName(for: voice.id.uuidString))
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

#Preview {
    VoicesTabView(viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()))
}
