import LucideSwift
import SwiftUI

/// Shared Voice Library for Write Text and the reader. Reader callers limit
/// the library to the engine captured by their saved project.
struct VoiceSettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    let previewPlayer: VoicePreviewPlayer
    private let restrictedEngine: Engine?
    private let selectedVoiceName: String?
    private let onVoiceSelected: ((String) -> Void)?
    @State private var previewTile: VoiceTile?
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: TTSViewModel,
        packs: VoicePackStore,
        voiceCloneViewModel: VoiceCloneViewModel,
        previewPlayer: VoicePreviewPlayer,
        restrictedEngine: Engine? = nil,
        selectedVoiceName: String? = nil,
        onVoiceSelected: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.packs = packs
        self.voiceCloneViewModel = voiceCloneViewModel
        self.previewPlayer = previewPlayer
        self.restrictedEngine = restrictedEngine
        self.selectedVoiceName = selectedVoiceName
        self.onVoiceSelected = onVoiceSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    shortcutsSection
                    availableVoicesSection
                    catalogue
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .sheet(item: $previewTile) { tile in
            VoicePreviewSheet(
                tiles: [tile], initialTileID: tile.id, previewPlayer: previewPlayer,
                onUseVoice: { selectedTile in
                    previewTile = nil
                    select(selectedTile)
                })
        }
        .onAppear(perform: synchronizeRestrictedSelection)
        .onDisappear { previewPlayer.stop() }
    }

    private var header: some View {
        HStack {
            Text("Voice Library")
                .appText(.labelStrong)

            Spacer()

            Button { dismiss() } label: {
                LucideIcon(.x, size: 20, color: .appPrimaryText)
                    .frame(width: 40, height: 40)
                    .background(Color.appSecondaryBackground.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Voice Library")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Shortcuts")

            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(shortcutTiles) { tile in
                        VoiceShortcutCard(
                            tile: tile,
                            isSelected: isSelected(tile),
                            onTap: { openPreview(for: tile) })
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var availableVoicesSection: some View {
        if !availableTiles.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Available Voices")

                ScrollView(.horizontal) {
                    LazyHGrid(
                        rows: [GridItem(.fixed(134)), GridItem(.fixed(134))], spacing: 12
                    ) {
                        ForEach(availableTiles) { tile in
                            VoiceLibraryCard(
                                tile: tile,
                                isSelected: isSelected(tile),
                                onTap: { openPreview(for: tile) })
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
                .frame(height: 280)
                .scrollIndicators(.hidden)
            }
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 26) {
            if shows(.kokoroAne) {
                ForEach(KokoroVariant.allCases) { variant in
                    catalogueSection(title: variant.displayName, tiles: kokoroTiles(for: variant))
                }
            }

            if shows(.pocketTts) {
                if !clonedVoiceTiles.isEmpty {
                    catalogueSection(title: "My Voices", tiles: clonedVoiceTiles)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("Pocket TTS")
                        Spacer()
                        Picker("Pocket language", selection: $viewModel.pocketLanguage) {
                            ForEach(PocketLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.appPrimaryText)
                    }
                    catalogueRows(pocketTiles)
                }
            }

        }
    }

    private var shortcutTiles: [VoiceTile] {
        if shows(.kokoroAne) {
            let byCode = Dictionary(uniqueKeysWithValues: kokoroTiles(for: .english).map { ($0.name, $0) })
            return ["af_heart", "af_sky", "am_adam"].compactMap { byCode[$0] }
        }
        return Array(allCatalogueTiles.prefix(3))
    }

    private var availableTiles: [VoiceTile] {
        allCatalogueTiles.filter(\.isAvailable)
    }

    private var allCatalogueTiles: [VoiceTile] {
        var tiles: [VoiceTile] = []
        if shows(.kokoroAne) {
            tiles += KokoroVariant.allCases.flatMap(kokoroTiles(for:))
        }
        if shows(.pocketTts) {
            tiles += clonedVoiceTiles
            tiles += pocketTiles
        }
        return tiles
    }

    private var clonedVoiceTiles: [VoiceTile] {
        voiceCloneViewModel.clonedVoices.map { voice in
            VoiceTile(
                id: "cloned-\(voice.id.uuidString)",
                voice: Voice(
                    code: voice.name,
                    tagline: "Cloned voice",
                    longDescription: "Your personal cloned voice."),
                engine: .pocketTts,
                engineLabel: "My Voice",
                isAvailable: true)
        }
    }

    private var pocketTiles: [VoiceTile] {
        VoiceCatalog.pocket.map { voice in
            VoiceTile(
                id: "pocket-\(viewModel.pocketLanguage.rawValue)-\(voice.code)",
                voice: voice,
                engine: .pocketTts,
                engineLabel: "Pocket TTS · \(viewModel.pocketLanguage.displayName)",
                isAvailable: packs.isPocketPackDownloaded(viewModel.pocketLanguage))
        }
    }

    private func kokoroTiles(for variant: KokoroVariant) -> [VoiceTile] {
        VoiceCatalog.voices(for: variant).map { voice in
            VoiceTile(
                id: "kokoro-\(variant.rawValue)-\(voice.code)",
                voice: voice,
                engine: .kokoroAne,
                engineLabel: variant == .english ? "Kokoro-ANE" : "Kokoro-ANE · \(variant.displayName)",
                isAvailable: packs.isKokoroPackReady(variant))
        }
    }

    private func catalogueSection(title: String, tiles: [VoiceTile]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            catalogueRows(tiles)
        }
    }

    private func catalogueRows(_ tiles: [VoiceTile]) -> some View {
        VStack(spacing: 0) {
            ForEach(tiles) { tile in
                VoiceLibraryRow(
                    tile: tile,
                    isSelected: isSelected(tile),
                    onTap: { openPreview(for: tile) })

                if tile.id != tiles.last?.id {
                    Divider()
                        .overlay(Color.appSecondaryBackground)
                        .padding(.leading, 72)
                }
            }
        }
        .background(Color.appSecondaryBackground.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).appText(.sectionTitle)
    }

    private func openPreview(for tile: VoiceTile) {
        guard tile.isAvailable else { return }
        previewTile = tile
    }

    private func select(_ tile: VoiceTile) {
        switch tile.engine {
        case .kokoroAne:
            guard let variant = VoiceCatalog.variant(forCode: tile.name) else { return }
            viewModel.engine = .kokoroAne
            viewModel.kokoroVariant = variant
            viewModel.kokoroVoice = tile.name
            viewModel.selectedClonedVoice = nil

        case .pocketTts:
            viewModel.engine = .pocketTts
            if let clonedVoice = voiceCloneViewModel.clonedVoices.first(where: { $0.name == tile.name }) {
                viewModel.pocketLanguage = clonedVoice.language
                viewModel.selectedClonedVoice = clonedVoice
            } else {
                viewModel.pocketVoice = tile.name
                viewModel.selectedClonedVoice = nil
            }
        }

        finishSelection(tile.name)
    }

    private func isSelected(_ tile: VoiceTile) -> Bool {
        if let selectedVoiceName {
            return selectedVoiceName == tile.name
        }

        switch tile.engine {
        case .kokoroAne:
            return viewModel.engine == .kokoroAne && viewModel.kokoroVoice == tile.name
        case .pocketTts:
            if let clonedVoice = voiceCloneViewModel.clonedVoices.first(where: { $0.name == tile.name }) {
                return viewModel.engine == .pocketTts && viewModel.selectedClonedVoice?.id == clonedVoice.id
            }
            return viewModel.engine == .pocketTts
                && viewModel.selectedClonedVoice == nil
                && viewModel.pocketVoice == tile.name
        }
    }

    private func shows(_ engine: Engine) -> Bool {
        // Pocket TTS is Studio-only now (voice cloning preview) — it never
        // produces or plays a reader page, so it's excluded here regardless
        // of restriction: both the unrestricted case (Write Text, which
        // also feeds the reader) and the reader's own restricted case.
        guard engine != .pocketTts else { return false }
        return restrictedEngine == nil || restrictedEngine == engine
    }

    private func finishSelection(_ voiceName: String) {
        onVoiceSelected?(voiceName)
        dismiss()
    }

    private func synchronizeRestrictedSelection() {
        guard restrictedEngine == .kokoroAne,
              let selectedVoiceName,
              let variant = VoiceCatalog.variant(forCode: selectedVoiceName)
        else { return }
        viewModel.kokoroVariant = variant
    }
}

private struct VoiceShortcutCard: View {
    let tile: VoiceTile
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 7) {
                VoiceLibraryAvatar(tile: tile, size: 76, isSelected: isSelected)
                Text(tile.displayName).appText(.rowTitle).lineLimit(1)
                Text(tile.descriptionText).appText(.labelDim).lineLimit(1)
            }
            .frame(width: 94)
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.58)
    }
}

private struct VoiceLibraryCard: View {
    let tile: VoiceTile
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 9) {
                VoiceLibraryAvatar(tile: tile, size: 62, isSelected: isSelected)
                Text(tile.displayName).appText(.rowTitle).lineLimit(1)
                Text(tile.descriptionText).appText(.labelDim).lineLimit(1)
            }
            .frame(width: 126, height: 134)
            .padding(.horizontal, 6)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? Color.appPrimaryText.opacity(0.6) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.58)
    }

    private var cardBackground: Color {
        isSelected ? Color.appSecondaryBackground.opacity(0.95) : Color.appSecondaryBackground.opacity(0.6)
    }
}

private struct VoiceLibraryRow: View {
    let tile: VoiceTile
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Catalogue rows use their trailing check as the only
                // selection marker; keep the avatar art unobscured.
                VoiceLibraryAvatar(tile: tile, size: 52, isSelected: false)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(tile.displayName).appText(.rowTitle)
                        Text(tile.countryFlag).font(AppTextStyle.label.font)
                    }
                    Text(tile.descriptionText).appText(.labelDim).lineLimit(1)
                }

                Spacer(minLength: 8)

                if !tile.isAvailable {
                    LucideIcon(.x, size: 16, color: .appSecondaryText)
                        .frame(width: 30, height: 30)
                        .background(Color.appBackground.opacity(0.7), in: Circle())
                } else if isSelected {
                    LucideIcon(.check, size: 16, color: .appBackground)
                        .frame(width: 30, height: 30)
                        .background(Color.appPrimaryText, in: Circle())
                } else {
                    LucideIcon(.chevronRight, size: 17, color: .appSecondaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.58)
    }
}

private struct VoiceLibraryAvatar: View {
    let tile: VoiceTile
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(VoiceCoverArt.assetName(for: tile.name))
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())

            if !tile.isAvailable {
                LucideIcon(.x, size: 12, color: .appBackground)
                    .frame(width: 24, height: 24)
                    .background(Color.appSecondaryText, in: Circle())
                    .offset(x: 5, y: -5)
            } else if isSelected {
                LucideIcon(.check, size: 13, color: .appBackground)
                    .frame(width: 24, height: 24)
                    .background(Color.appPrimaryText, in: Circle())
                    .offset(x: 5, y: -5)
            }
        }
        .frame(width: size + 8, height: size + 8)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    VoiceSettingsSheet(
        viewModel: viewModel,
        packs: viewModel.packs,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        previewPlayer: VoicePreviewPlayer())
}
