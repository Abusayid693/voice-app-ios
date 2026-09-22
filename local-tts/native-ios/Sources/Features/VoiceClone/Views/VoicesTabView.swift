import LucideSwift
import SwiftUI

/// The Voices tab: manage cloned voices — create new ones, preview or
/// delete existing ones. Selecting one for actual generation happens from
/// VoiceSettingsSheet's "My Voices" section, not here.
struct VoicesTabView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    // Only used to update navigationChrome when this tab pushes a screen —
    // see NavigationChromeVisibility.
    let app: AppEnvironment
    @Binding var homeMode: HomeMode
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
                    // Matches ImportHomeView's own gap under its nav
                    // title (.padding(.top, 8) on its content), and
                    // LibraryTabView's List (same fix, same reason).
                    .contentMargins(.top, 8, for: .scrollContent)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HomeModeSwitcher(
                        selection: $homeMode,
                        foreground: .appPrimaryText,
                        selectedBackground: .appSecondaryBackground,
                        trackBackground: Color.appPrimaryText.opacity(0.12))
                }
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
            // Root tab bar/floating "+" button only at this screen's own
            // root — see NavigationChromeVisibility.
            .tabRootChrome(app.navigationChrome, isPushed: voiceCloneRoute != nil)
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
                .appText(.body)
            Button("Create your own voice") { isCreateVoicePresented = true }
                .buttonStyle(.primary)
                .padding(.horizontal, 40)
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
                    SmallVoiceCard(avatarSeed: voice.id.uuidString, name: voice.name) {
                        viewModel.togglePreview(for: voice)
                    }
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
                            .appText(.label)
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
        VoiceCard(
            avatarSeed: voice.id.uuidString,
            name: voice.name,
            subtitle: "\(voice.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(voice.language.displayName)",
            isPlaying: viewModel.previewingVoiceID == voice.id,
            isLoading: viewModel.previewingVoiceID == voice.id && viewModel.isPreviewLoading,
            onPlayToggle: { viewModel.togglePreview(for: voice) }
        )
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return VoicesTabView(viewModel: app.voiceClone, app: app, homeMode: .constant(.studio))
}
