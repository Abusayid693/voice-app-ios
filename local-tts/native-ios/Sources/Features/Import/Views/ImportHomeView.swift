import SwiftUI

/// The app's default screen — a consumer-facing "Import" landing page
/// (redesign target: paste/upload/scan/write actions, trending demo rows,
/// a Setup entry point for the two voice packs). Only "Write text" is
/// functional today; the rest are visual placeholders per the current
/// design pass.
struct ImportHomeView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    // Owned here (not TTSViewModel) — book browsing is a separate concern
    // from TTS orchestration, and outlives this view's re-renders as long
    // as the Import tab stays alive, so "See all" resumes pagination
    // instead of refetching from page 1.
    @StateObject private var trendingBooksViewModel = TrendingBooksViewModel()
    // Which voice's preview sheet is open, if any — pure navigation state
    // for this screen, not shared elsewhere, so it lives here rather than
    // on TTSViewModel.
    @State private var selectedVoiceTile: VoiceTile?
    @State private var isCreateVoicePresented = false
    @State private var voiceCloneRoute: VoiceCloneRoute?
    @State private var isSettingsPresented = false
    // Set when tapping a Kokoro entry in Projects — see playFromSavedGeneration's
    // doc comment for why "opening" a saved entry means regenerating it fresh.
    @State private var readAlongGenerationID: KokoroGeneration.ID?

    private var isFullyDownloaded: Bool {
        viewModel.isKokoroPackReady && viewModel.isPocketPackDownloaded
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    actionGrid
                    trendingVoicesSection
                    createYourOwnVoiceRow
                    whatsTrendingSection
                    createYourOwnBookRow
                    projectsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    setupButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    settingsButton
                }
            }
            .task { await trendingBooksViewModel.loadInitialPageIfNeeded() }
            .navigationDestination(item: $voiceCloneRoute) { route in
                switch route {
                case .instantClone:
                    InstantCloneView(viewModel: voiceCloneViewModel) { voiceCloneRoute = nil }
                case .upload:
                    UploadVoiceView(viewModel: voiceCloneViewModel) { voiceCloneRoute = nil }
                }
            }
            .navigationDestination(item: $readAlongGenerationID) { generationID in
                ReadAlongPlayerView(generationID: generationID, viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isSetupPresented) {
            SetupSheet(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isWriteTextPresented) {
            WriteTextView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel)
        }
        .sheet(isPresented: $isCreateVoicePresented) {
            CreateVoiceSheet { route in
                isCreateVoicePresented = false
                voiceCloneRoute = route
            }
        }
        .sheet(item: $selectedVoiceTile) { tile in
            VoicePreviewSheet(tile: tile, viewModel: viewModel)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    private var setupButton: some View {
        Button {
            viewModel.isSetupPresented = true
        } label: {
            Label("Setup", systemImage: isFullyDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
        }
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Paste a link", systemImage: "link", action: {})
            ImportActionCard(title: "Upload a file", systemImage: "doc", action: {})
            ImportActionCard(title: "Scan text", systemImage: "viewfinder", action: {})
            ImportActionCard(title: "Write text", systemImage: "character.cursor.ibeam") {
                viewModel.isWriteTextPresented = true
            }
        }
    }

    // Every real voice from both packs, not just a curated few — shown
    // regardless of download state (per the request to "show all voices
    // available"); isAvailable just controls cover art vs. a gradient
    // placeholder below.
    private var voiceTiles: [VoiceTile] {
        TTSViewModel.kokoroVoices.map {
            VoiceTile(
                id: "kokoro-\($0)", name: $0, engine: .kokoroAne, engineLabel: "Kokoro-ANE",
                isAvailable: viewModel.isKokoroPackReady)
        } + TTSViewModel.pocketVoices.map {
            VoiceTile(
                id: "pocket-\($0)", name: $0, engine: .pocketTts, engineLabel: "Pocket TTS",
                isAvailable: viewModel.isPocketPackDownloaded)
        }
    }

    private var trendingVoicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending voices").font(.headline).foregroundStyle(Color.appPrimaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(84)), GridItem(.fixed(84))], spacing: 12) {
                    ForEach(voiceTiles) { tile in
                        VoiceTileView(tile: tile, viewModel: viewModel) {
                            selectedVoiceTile = tile
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // Real, unlike createYourOwnBookRow below — opens the same CreateVoiceSheet
    // (Instant Clone / Upload file) as the Voices tab's own entry point.
    private var createYourOwnVoiceRow: some View {
        Button {
            isCreateVoicePresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(Color.appPrimaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own voice").font(.subheadline).bold()
                        .foregroundStyle(Color.appPrimaryText)
                    Text("Clone your voice in seconds").font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var whatsTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What's trending").font(.headline).foregroundStyle(Color.appPrimaryText)
                Spacer()
                NavigationLink {
                    AllTrendingBooksView(viewModel: trendingBooksViewModel)
                } label: {
                    Text("See all")
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            if let loadErrorMessage = trendingBooksViewModel.loadErrorMessage, trendingBooksViewModel.books.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadErrorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                    Button("Retry") { Task { await trendingBooksViewModel.retry() } }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(trendingBooksViewModel.books.prefix(5)) { book in
                            TrendingBookCard(book: book)
                        }
                        if trendingBooksViewModel.isLoading {
                            ProgressView()
                                .frame(width: 110, height: 110)
                        }
                    }
                }
            }
        }
    }

    private var createYourOwnBookRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.appPrimaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own book").font(.subheadline).bold()
                        .foregroundStyle(Color.appPrimaryText)
                    Text("Craft your own story in seconds").font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Real generations (latest 5, newest first) once any exist; falls back
    // to the static demo row + a "Create your own project" entry point
    // (no action yet, matching createYourOwnBookRow's own no-op) while the
    // library is still empty.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects").font(.headline).foregroundStyle(Color.appPrimaryText)
            if libraryViewModel.savedGenerations.isEmpty {
                ForEach(DemoContent.projects) { project in
                    projectRow(title: project.title, subtitle: project.subtitle, updatedLabel: project.updatedLabel)
                }
                createYourOwnProjectRow
            } else {
                ForEach(libraryViewModel.savedGenerations.prefix(5)) { generation in
                    projectRow(
                        title: VoiceDisplayName.forCode(generation.voiceName),
                        subtitle: generation.text,
                        updatedLabel: "Updated \(generation.createdAt.formatted(date: .abbreviated, time: .omitted))"
                    )
                    // Kokoro only — plays the saved audio straight from
                    // disk when available (LibraryPlayback), regenerating
                    // only as a fallback; there's no Pocket player yet.
                    .onTapGesture {
                        guard generation.engine == .kokoroAne else { return }
                        if let newID = LibraryPlayback.open(
                            generation, ttsViewModel: viewModel, libraryViewModel: libraryViewModel)
                        {
                            readAlongGenerationID = newID
                        }
                    }
                }
            }
        }
    }

    private func projectRow(title: String, subtitle: String, updatedLabel: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appSecondaryBackground)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                Text(subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
                Text(updatedLabel).font(.caption2).foregroundStyle(Color.appTertiaryText)
            }
            Spacer()
            Image(systemName: "play.circle.fill").font(.title2)
                .foregroundStyle(Color.appPrimaryText)
        }
        .contentShape(Rectangle())
    }

    private var createYourOwnProjectRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.appPrimaryText)
                Text("Create your own project").font(.subheadline).bold()
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ImportActionCard: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.appPrimaryText)
                Text(title)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 80)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        }
        .buttonStyle(.plain)
    }
}

struct VoiceTile: Identifiable {
    let id: String
    // Raw voice code passed to the engine (e.g. "af_alloy", "bill_boerst") —
    // kept separate from the display name so cover-art selection stays keyed
    // off the same stable identifier regardless of how it's shown.
    let name: String
    let engine: Engine
    let engineLabel: String
    let isAvailable: Bool

    // "af_alloy" -> "Alloy", "bill_boerst" -> "Bill Boerst".
    var displayName: String { VoiceDisplayName.forCode(name) }
}

/// One row per voice: cover image, name + engine label, a play icon at the
/// trailing end — mirrors the mockup's trending-voice row layout. Tapping
/// anywhere on the row opens VoicePreviewSheet rather than playing inline;
/// the icon just reflects whether this voice's preview is the one
/// currently playing (started from that sheet).
private struct VoiceTileView: View {
    let tile: VoiceTile
    @ObservedObject var viewModel: TTSViewModel
    let onTap: () -> Void

    private var isPreviewing: Bool { viewModel.previewingVoiceID == tile.name }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                avatar
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.displayName)
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                    Text(tile.engineLabel)
                        .font(.caption2)
                        .foregroundStyle(Color.appTertiaryText)
                }

                Spacer(minLength: 8)

                Image(systemName: isPreviewing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.appPrimaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 268, height: 84)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.6)
    }

    @ViewBuilder
    private var avatar: some View {
        if tile.isAvailable {
            Image(VoiceCoverArt.assetName(for: tile.name))
                .resizable()
                .scaledToFill()
        } else {
            VoiceCoverArt.placeholderGradient(for: tile.name)
        }
    }
}

/// Voice avatars: a real cover image (cycled from the 5 bundled
/// `VoiceCoverN` assets) for voices whose pack is downloaded, or a
/// gradient placeholder — picked deterministically from the voice's name,
/// not re-randomized on every redraw — for voices that aren't available yet.
enum VoiceCoverArt {
    // Real, per-voice AI-generated avatars (issue #18) — keyed by the exact
    // voice code, not the generic cycling covers below. Sparse on purpose:
    // only voices with a generated avatar appear here; every other voice
    // still falls back to the hashed generic cover until its own avatar
    // exists. Add an entry here as each new avatar lands.
    private static let realAvatarAssetNames: [String: String] = [
        "af_heart": "VoiceAvatar_af_heart",
        "af_alloy": "VoiceAvatar_af_alloy",
    ]

    private static let assetNames = [
        "VoiceCover1", "VoiceCover2", "VoiceCover3", "VoiceCover4", "VoiceCover5", "VoiceCover6",
    ]

    static func assetName(for voiceName: String) -> String {
        if let realAvatar = realAvatarAssetNames[voiceName] {
            return realAvatar
        }
        let sum = voiceName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return assetNames[sum % assetNames.count]
    }

    static func placeholderGradient(for voiceName: String) -> LinearGradient {
        .stablePlaceholder(seed: voiceName)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ImportHomeView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel())
}
