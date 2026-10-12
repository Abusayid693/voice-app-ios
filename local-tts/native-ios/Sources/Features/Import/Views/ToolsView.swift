import AVFoundation
import LucideSwift
import SwiftUI

/// The retained Tools tab root. App-wide file picking and reader presentation
/// remain owned by `RootTabView`; catalog browsing is feature-local.
struct ToolsView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let app: AppEnvironment
    let onAddBooks: () -> Void
    let onOpenProject: (SavedGeneration) -> Void
    let onImportDownloadedBook: (URL, BookImportFormat) async -> Void

    @AppStorage("tools.catalogIntroductionCompleted.v1")
    private var hasCompletedCatalogIntroduction = false
    @StateObject private var catalogStore = CatalogSourceStore()
    @State private var isWriteTextPresented = false
    @State private var isAddCatalogPresented = false
    @State private var isCatalogExplainerPresented = false
    @State private var selectedCatalog: CatalogSource?
    @State private var pendingCatalogIntroduction: CatalogSource?
    @State private var opensCatalogAfterIntroduction = false
    @State private var pendingCatalogDeletion: CatalogSource?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header

                    toolGridSection("Create & Import", onTapHeader: showCatalogExplanation) {
                        ToolGridCard(icon: .pencil, title: "Write text") {
                            isWriteTextPresented = true
                        }

                        ToolGridCard(icon: .upload, title: "Add file", onTap: onAddBooks)

                        ToolGridCard(icon: .link, title: "Share Link", isEnabled: false) {}

                        ToolGridCard(icon: .image, title: "Add Image", isEnabled: false) {}
                    }

                    catalogSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 132)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $isWriteTextPresented) {
            WriteTextView(library: libraryViewModel, viewModel: app.tts) { project in
                onOpenProject(project)
            }
        }
        .navigationDestination(item: $selectedCatalog) { source in
            CatalogBrowserView(source: source, onImport: onImportDownloadedBook)
        }
        .sheet(isPresented: $isAddCatalogPresented) {
            AddCatalogSheet { name, address in
                catalogStore.add(name: name, address: address)
            }
        }
        .sheet(
            isPresented: $isCatalogExplainerPresented,
            onDismiss: finishCatalogExplainerDismissal
        ) {
            CatalogExplainerSheet(
                destinationName: pendingCatalogIntroduction?.name,
                onContinue: completeCatalogIntroduction,
                onLater: { opensCatalogAfterIntroduction = false })
        }
        .alert(
            "Delete Catalog?",
            isPresented: Binding(
                get: { pendingCatalogDeletion != nil },
                set: { if !$0 { pendingCatalogDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingCatalogDeletion = nil }
            Button("Delete", role: .destructive) {
                if let pendingCatalogDeletion {
                    catalogStore.delete(pendingCatalogDeletion)
                }
                pendingCatalogDeletion = nil
            }
        } message: {
            Text("\(pendingCatalogDeletion?.name ?? "This catalog") will be removed from Tools.")
        }
    }

    private var header: some View {
        Text("Tools")
            .font(AppEditorialFont.regular(size: 36, relativeTo: .largeTitle))
            .foregroundStyle(Color.appPrimaryText)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two-column grid of `ToolGridCard`s — Write text, Add file, and
    /// the "Coming Soon" actions (Share Link, Add Image) folded into one
    /// section rather than two, matching a picked reference screenshot's
    /// own category-tile layout (icon-tile-plus-label cards in a grid) over
    /// this app's own colors — the reference's book-cover collages are
    /// specific content browsing doesn't apply to; a Lucide icon in a
    /// square tile fills that same slot here instead.
    ///
    /// `onTapHeader`, when given, makes the title row tappable with a
    /// trailing chevron — exactly `catalogSection`'s own header button
    /// below, copied rather than factored out only because this is the
    /// single other call site. "Create & Import" passes
    /// `showCatalogExplanation` for now, reusing Catalogs' own explainer
    /// sheet/state rather than standing up a second one — a placeholder
    /// until this section gets its own.
    private func toolGridSection<Content: View>(
        _ title: String,
        onTapHeader: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Both spacings here (title-to-grid, and between cards) match
        // catalogSection's own 12pt so the two sections read as one
        // consistent rhythm rather than two slightly different ones.
        VStack(alignment: .leading, spacing: 12) {
            if let onTapHeader {
                Button(action: onTapHeader) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(AppTextStyle.sectionTitle.font)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.appTertiaryText)
                    }
                    .foregroundStyle(Color.appPrimaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel("About \(title)")
            } else {
                Text(title)
                    .font(AppTextStyle.sectionTitle.font)
                    .foregroundStyle(Color.appPrimaryText)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                spacing: 12
            ) {
                content()
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: showCatalogExplanation) {
                    HStack(spacing: 8) {
                        Text("Catalogs")
                            .font(AppTextStyle.sectionTitle.font)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.appTertiaryText)
                    }
                    .foregroundStyle(Color.appPrimaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel("About catalogs")

                Spacer(minLength: 0)

                Button {
                    isAddCatalogPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                        .frame(width: 34, height: 34)
                        .background(
                            Color.appSecondaryBackground.opacity(0.9),
                            in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel("Add catalog")
            }

            VStack(spacing: 12) {
                ForEach(catalogStore.allSources) { source in
                    CatalogSourceCard(
                        source: source,
                        onOpen: { openCatalog(source) },
                        onDelete: source.isCustom
                            ? { pendingCatalogDeletion = source }
                            : nil)
                }
            }
        }
    }

    private func openCatalog(_ source: CatalogSource) {
        guard !hasCompletedCatalogIntroduction else {
            selectedCatalog = source
            return
        }
        pendingCatalogIntroduction = source
        opensCatalogAfterIntroduction = false
        isCatalogExplainerPresented = true
    }

    private func showCatalogExplanation() {
        pendingCatalogIntroduction = nil
        opensCatalogAfterIntroduction = false
        isCatalogExplainerPresented = true
    }

    private func completeCatalogIntroduction() {
        hasCompletedCatalogIntroduction = true
        opensCatalogAfterIntroduction = pendingCatalogIntroduction != nil
    }

    private func finishCatalogExplainerDismissal() {
        let destination = opensCatalogAfterIntroduction
            ? pendingCatalogIntroduction
            : nil
        pendingCatalogIntroduction = nil
        opensCatalogAfterIntroduction = false
        if let destination {
            selectedCatalog = destination
        }
    }
}

/// One "Create & Import" grid cell: a square icon tile beside a single-line
/// label, inside an outlined (not solid-filled) rounded card — the shape
/// the reference screenshot's own category tiles use, kept to this app's
/// `appBackground`/`appSecondaryBackground`/`appPrimaryText` palette rather
/// than the reference's own colors.
private struct ToolGridCard: View {
    let icon: LucideIconName
    let title: String
    var isEnabled = true
    let onTap: () -> Void

    // A 2-column grid leaves roughly 170-190pt per card — the tile has to
    // stay small enough that the label retains enough width for one line.
    // The first pass used 92pt here, which left ~50pt for text and forced
    // mid-word breaks ("Writ" / "e a…").
    private let tileSize: CGFloat = 56

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                iconTile

                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.appSecondaryBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.appPrimaryText.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.pressOpacity)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.appBackground)
            .frame(width: tileSize, height: tileSize)
            .overlay { LucideIcon(icon, size: 20, color: Color.appPrimaryText) }
    }
}

private struct CatalogSourceCard: View {
    let source: CatalogSource
    let onOpen: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 15) {
                logo

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)

                    Text(source.sourceLabel)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Spacer(minLength: onDelete == nil ? 4 : 42)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.pressOpacity)
        .accessibilityLabel(source.name)
        .accessibilityHint("Opens this book catalog")
        .overlay(alignment: .topTrailing) {
            if let onDelete {
                Menu {
                    Button("Delete Catalog", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(8)
                .accessibilityLabel("Options for \(source.name)")
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        let style = CatalogCardStyle(source: source)
        RoundedRectangle(cornerRadius: 14)
            .fill(style.logoBackground)
            .frame(width: 64, height: 64)
            .overlay {
                if let assetName = style.assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(style.logoInset)
                } else {
                    Text(monogram)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(style.logoForeground)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var cardBackground: some View {
        let style = CatalogCardStyle(source: source)
        return RoundedRectangle(cornerRadius: 22)
            .fill(
                LinearGradient(
                    colors: style.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            .overlay {
                RadialGradient(
                    colors: [Color.white.opacity(0.10), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
    }

    private var monogram: String {
        let words = source.name.split(whereSeparator: \.isWhitespace)
        if words.count > 1 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(source.name.prefix(2)).uppercased()
    }
}

private struct CatalogCardStyle {
    let gradient: [Color]
    let logoBackground: Color
    let logoForeground: Color
    let assetName: String?
    let logoInset: CGFloat

    init(source: CatalogSource) {
        switch source.id {
        case "project-gutenberg":
            gradient = [
                Color(hex: 0x7B2523),
                Color(hex: 0x661C1D),
                Color(hex: 0x4A1417),
            ]
            logoBackground = Color(hex: 0xF3E6D3)
            logoForeground = Color(hex: 0x7A3734)
            assetName = nil
            logoInset = 0

        case "standard-ebooks":
            gradient = [
                Color(hex: 0x2D468E),
                Color(hex: 0x223777),
                Color(hex: 0x172653),
            ]
            logoBackground = Color(hex: 0x343E4A)
            logoForeground = Color.white.opacity(0.92)
            assetName = "CatalogStandardEbooks"
            logoInset = 0

        default:
            let palettes: [[Color]] = [
                [Color(hex: 0x356D69), Color(hex: 0x173F43)],
                [Color(hex: 0x604A7D), Color(hex: 0x30264A)],
                [Color(hex: 0x80503B), Color(hex: 0x43271F)],
                [Color(hex: 0x5A6942), Color(hex: 0x2C351F)],
            ]
            let checksum = source.id.utf8.reduce(0) { ($0 + Int($1)) % palettes.count }
            gradient = palettes[checksum]
            logoBackground = Color.white.opacity(0.13)
            logoForeground = Color.white.opacity(0.92)
            assetName = nil
            logoInset = 0
        }
    }
}

private struct CatalogExplainerSheet: View {
    let destinationName: String?
    let onContinue: () -> Void
    let onLater: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardBottomSheet(
            title: "A world of books, ready when you are",
            detents: [.custom(CatalogExplainerDetent.self)]
        ) {
            CatalogExplainerVideo()

            Text(
                "Browse trusted ebook catalogs, choose a PDF or EPUB, "
                    + "and import it directly into My Shelf for reading and listening."
            )
            .font(AppTextStyle.body.font)
            .foregroundStyle(Color.appSecondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Text("Catalogs are third-party websites. Availability and usage rights can vary by title and country.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appTertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(primaryTitle) {
                    onContinue()
                    dismiss()
                }
                .font(.system(.body, design: .rounded, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.tabSelected, in: Capsule())
                .buttonStyle(.pressOpacity)

                Button("MAYBE LATER") {
                    onLater()
                    dismiss()
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.appSecondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    Color.appSecondaryBackground.opacity(0.82),
                    in: Capsule())
                .buttonStyle(.pressOpacity)
            }
        }
    }

    private var primaryTitle: String {
        destinationName == nil ? "GOT IT" : "CONTINUE"
    }
}

private struct CatalogExplainerDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, max(320, context.maxDetentValue * 0.82 - 80))
    }
}

private struct CatalogExplainerVideo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let videoSize = CGSize(width: 360, height: 442)
    private let containerHeight: CGFloat = 184

    var body: some View {
        ZStack {
            Color(hex: 0x0C0A0E)

            if let url = Bundle.main.url(
                forResource: "catalog-explainer",
                withExtension: "mp4"
            ) {
                LoopingVideoPlayerView(
                    url: url,
                    videoGravity: .resizeAspect,
                    isPaused: reduceMotion)
                    .frame(
                        width: containerHeight * videoSize.width / videoSize.height,
                        height: containerHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: containerHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Catalog import demonstration")
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        ToolsView(
            libraryViewModel: app.library,
            app: app,
            onAddBooks: {},
            onOpenProject: { _ in },
            onImportDownloadedBook: { _, _ in })
    }
    .preferredColorScheme(.dark)
}
