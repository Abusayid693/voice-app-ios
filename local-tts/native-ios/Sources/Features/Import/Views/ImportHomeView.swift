import LucideSwift
import SwiftUI

/// Reports whether a ScrollView is parked at (or within `threshold` of) its
/// top, so ImportHomeView can fade the Setup pointer out as soon as the user
/// scrolls away from it.
///
/// Uses `.onScrollGeometryChange` (iOS 18+) rather than the older
/// GeometryReader-in-the-content's-`.background` + PreferenceKey recipe. That
/// recipe silently stopped working: modern ScrollView doesn't re-evaluate a
/// background GeometryReader on every scroll tick, so the preference never
/// fired and the "at top" flag was stuck at `true` forever no matter which
/// coordinate space it measured against.
///
/// On iOS 17 there is no equivalent API, so the pointer simply stays put
/// until the packs finish downloading — it's a decorative onboarding hint,
/// and that degradation is preferable to reinstating the broken recipe.
private struct ScrolledToTopObserver: ViewModifier {
    @Binding var isAtTop: Bool
    var threshold: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // At rest contentOffset.y == -contentInsets.top (the nav bar
                // and large title are part of the top inset), so the sum —
                // not contentOffset alone — is the real distance scrolled.
                geometry.contentOffset.y + geometry.contentInsets.top <= threshold
            } action: { _, atTop in
                guard atTop != isAtTop else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isAtTop = atTop }
            }
        } else {
            content
        }
    }
}

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
    // Setup pointer only makes sense while its target is still visible at
    // the top of the screen — hide it the moment the user scrolls away
    // from the top, rather than have it float over unrelated content.
    // Driven by ScrolledToTopObserver above.
    @State private var isScrolledToTop = true

    private var isFullyDownloaded: Bool {
        viewModel.isKokoroPackReady && viewModel.isPocketPackDownloaded
    }

    var body: some View {
        // The pointer is a sibling of the *whole* NavigationStack, not a
        // layer inside it. Anything placed inside the stack is positioned
        // relative to the stack's content area, and that area moves: when
        // the large "Import" title collapses into the inline bar on scroll,
        // the content area's origin rises by the title's height, dragging
        // any inner overlay up with it (which is what made the pointer look
        // like it scrolled, then "stuck" once the collapse finished). Out
        // here the coordinate space is the screen's safe area, which never
        // changes — and that's the same space the toolbar button lives in.
        ZStack(alignment: .topTrailing) {
            navigationContent

            if !isFullyDownloaded && isScrolledToTop {
                setupPointer
                    // 40pt down clears the 44pt nav bar; 100pt in from the
                    // trailing edge lands under "Setup" rather than the cog.
                    .padding(.top, 50)
                    .padding(.trailing, 100)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var navigationContent: some View {
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
            .scrollIndicators(.hidden)
            .modifier(ScrolledToTopObserver(isAtTop: $isScrolledToTop))
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Home")
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
            Label(
                title: { Text("Setup") },
                icon: {
                    LucideIcon(isFullyDownloaded ? .circleCheck : .circleArrowDown)
                })
        }
    }

    // Floats in screen space outside the NavigationStack (see body) so it
    // stays pinned under the Setup toolbar button no matter how far the
    // page scrolls or whether the large title has collapsed. Never attached
    // to the button itself — that would make it participate in the
    // toolbar's own layout and push the other item around.
    private var setupPointer: some View {
        Image("SetupPointer")
            .resizable()
            .scaledToFit()
            .frame(width: 28.8, height: 48)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            LucideIcon(.cog)
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Paste a link", icon: .link, action: {})
            ImportActionCard(title: "Upload a file", icon: .file, action: {})
            ImportActionCard(title: "Scan text", icon: .scan, action: {})
            ImportActionCard(title: "Write text", icon: .textCursor) {
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
            // Cancels the parent VStack's .padding(.horizontal) (default,
            // 16pt) just for this scroll view's own clipping bounds, then
            // re-adds the same 16pt as content inset — so cards still start
            // flush with the rest of the screen, but scrolling isn't
            // clipped early at that boundary; the last/first card can
            // slide all the way to the true screen edge.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(84)), GridItem(.fixed(84))], spacing: 12) {
                    ForEach(voiceTiles) { tile in
                        VoiceTileView(tile: tile, viewModel: viewModel) {
                            selectedVoiceTile = tile
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -16)
        }
    }

    // Real, unlike createYourOwnBookRow below — opens the same CreateVoiceSheet
    // (Instant Clone / Upload file) as the Voices tab's own entry point.
    private var createYourOwnVoiceRow: some View {
        Button {
            isCreateVoicePresented = true
        } label: {
            HStack(spacing: 12) {
                LucideIcon(.mic, style: .filled, size: 28, color: Color.appPrimaryText)
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
                LucideIcon(.circlePlus, size: 28, color: Color.appPrimaryText)
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
            LucideIcon(.circlePlay, size: 22, color: Color.appPrimaryText)
        }
        .contentShape(Rectangle())
    }

    private var createYourOwnProjectRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                LucideIcon(.circlePlus, size: 28, color: Color.appPrimaryText)
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
    let icon: LucideIconName
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                LucideIcon(icon, size: 20, color: Color.appPrimaryText)
                Text(title)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
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

    // A short persona tagline ("Warm and friendly") in place of the raw
    // engine label, falling back to that label for voices without one.
    var descriptionText: String { VoiceDescription.tagline(for: name, fallback: engineLabel) }
}

/// One row per voice: cover image, name, a short persona tagline, and a
/// trailing play/pause indicator (reflects whether this voice's preview is
/// the one currently playing, started from VoicePreviewSheet). The whole
/// card is the tap target — tapping opens VoicePreviewSheet.
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

                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                    Text(tile.descriptionText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appTertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                LucideIcon(isPreviewing ? .circlePause : .circlePlay, size: 22, color: Color.appTertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .frame(width: 268, height: 84)
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
        "af_nova": "VoiceAvatar_af_nova",
        "af_aoede": "VoiceAvatar_af_aoede",
        "af_bella": "VoiceAvatar_af_bella",
        "af_jessica": "VoiceAvatar_af_jessica",
        "af_kore": "VoiceAvatar_af_kore",
        "af_nicole": "VoiceAvatar_af_nicole",
        "af_river": "VoiceAvatar_af_river",
        "af_sarah": "VoiceAvatar_af_sarah",
        "af_sky": "VoiceAvatar_af_sky",
        "am_adam": "VoiceAvatar_am_adam",
        "am_liam": "VoiceAvatar_am_liam",
        "bf_alice": "VoiceAvatar_bf_alice",
        "bm_daniel": "VoiceAvatar_bm_daniel",
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

/// Short persona taglines shown under a voice's name in Trending voices,
/// instead of the raw engine label — same personas used to brief the
/// avatar images (issue #18), condensed to a couple of words. Sparse like
/// `VoiceCoverArt.realAvatarAssetNames`: falls back to the engine label for
/// any voice without one yet (currently all of Pocket TTS).
enum VoiceDescription {
    private static let taglines: [String: String] = [
        "af_heart": "Warm and friendly",
        "af_alloy": "Poised and composed",
        "af_aoede": "Dreamy and artistic",
        "af_bella": "Warm and confident",
        "af_jessica": "Friendly and professional",
        "af_kore": "Bright and youthful",
        "af_nicole": "Sophisticated and polished",
        "af_nova": "Vibrant and energetic",
        "af_river": "Free-spirited and relaxed",
        "af_sarah": "Sweet and genuine",
        "af_sky": "Bright and airy",
        "am_adam": "Warm and easygoing",
        "am_echo": "Sharp and composed",
        "am_eric": "Friendly and warm",
        "am_fenrir": "Rugged, deep voice",
        "am_liam": "Youthful and relaxed",
        "am_michael": "Reliable and warm",
        "am_onyx": "Sleek and cool",
        "am_puck": "Playful and mischievous",
        "am_santa": "Warm and jolly",
        "bf_alice": "Elegant and refined",
        "bf_emma": "Poised and elegant",
        "bf_isabella": "Graceful and refined",
        "bf_lily": "Gentle and delicate",
        "bm_daniel": "Distinguished and calm",
        "bm_fable": "Warm storyteller",
        "bm_george": "Distinguished and composed",
        "bm_lewis": "Friendly and approachable",
    ]

    static func tagline(for voiceName: String, fallback: String) -> String {
        taglines[voiceName] ?? fallback
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ImportHomeView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel())
}
