import LucideSwift
import SwiftUI

/// The reader's Voice Library. Kokoro is the only engine now, so this only
/// ever shows the Kokoro catalogue. `restrictedEngine`/`synchronizeRestrictedSelection`
/// stay — a saved project still persists its engine and the reader still
/// passes it, and `restrictedEngine == nil` (the `#Preview` below, any
/// caller that omits it) is a real, distinct case from `.kokoroAne`.
struct VoiceSettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore
    let previewPlayer: VoicePreviewPlayer
    private let restrictedEngine: Engine?
    private let selectedVoiceName: String?
    private let onVoiceSelected: ((String) -> Void)?
    @State private var previewTile: VoiceTile?
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: TTSViewModel,
        packs: VoicePackStore,
        previewPlayer: VoicePreviewPlayer,
        restrictedEngine: Engine? = nil,
        selectedVoiceName: String? = nil,
        onVoiceSelected: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.packs = packs
        self.previewPlayer = previewPlayer
        self.restrictedEngine = restrictedEngine
        self.selectedVoiceName = selectedVoiceName
        self.onVoiceSelected = onVoiceSelected
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    shortcutsSection
                    availableVoicesSection
                    catalogue
                }
                .padding(.horizontal, 20)
                .padding(.top, 82)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)

            header
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground {
            TexturedDarkBackground(variant: .sidebar)
        }
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
        ZStack {
            ProgressiveHeaderBlur()

            HStack {
                Text("Voice Library")
                    .font(AppEditorialFont.regular(size: 36, relativeTo: .title))
                    .foregroundStyle(Color.appPrimaryText)
                    .accessibilityAddTraits(.isHeader)

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
        }
        .frame(height: 70)
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
                        rows: [GridItem(.fixed(150)), GridItem(.fixed(150))], spacing: 12
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
                .frame(height: 312)
                .scrollIndicators(.hidden)
            }
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(KokoroVariant.allCases) { variant in
                catalogueSection(title: variant.displayName, tiles: kokoroTiles(for: variant))
            }
        }
    }

    private var shortcutTiles: [VoiceTile] {
        let byCode = Dictionary(uniqueKeysWithValues: kokoroTiles(for: .english).map { ($0.name, $0) })
        return ["af_heart", "af_sky", "am_adam"].compactMap { byCode[$0] }
    }

    private var availableTiles: [VoiceTile] {
        allCatalogueTiles.filter(\.isAvailable)
    }

    private var allCatalogueTiles: [VoiceTile] {
        KokoroVariant.allCases.flatMap(kokoroTiles(for:))
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
        guard let variant = VoiceCatalog.variant(forCode: tile.name) else { return }
        viewModel.kokoroVariant = variant
        viewModel.kokoroVoice = tile.name
        finishSelection(tile.name)
    }

    private func isSelected(_ tile: VoiceTile) -> Bool {
        if let selectedVoiceName {
            return selectedVoiceName == tile.name
        }
        return viewModel.kokoroVoice == tile.name
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
            VStack(spacing: 7) {
                VoiceLibraryAvatar(tile: tile, size: 62, isSelected: isSelected)
                Text(tile.displayName).appText(.rowTitle).lineLimit(1)
                Text(tile.descriptionText).appText(.labelDim).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(width: 138, height: 150, alignment: .top)
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
        previewPlayer: VoicePreviewPlayer())
}
