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

    @StateObject private var catalogStore = CatalogSourceStore()
    @State private var isWriteTextPresented = false
    @State private var isPlaybackLabPresented = false
    @State private var isAddCatalogPresented = false
    @State private var selectedCatalog: CatalogSource?
    @State private var pendingCatalogDeletion: CatalogSource?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header

                    toolSection("Create & Import") {
                        ToolActionRow(
                            icon: .pencil,
                            title: "Write a Text",
                            subtitle: "Type or paste text to turn into audio"
                        ) {
                            isWriteTextPresented = true
                        }

                        ToolActionRow(
                            icon: .upload,
                            title: "Upload File",
                            subtitle: "Import a PDF or EPUB from your device",
                            onTap: onAddBooks)
                    }

                    toolSection("Catalogs") {
                        ForEach(catalogStore.allSources) { source in
                            CatalogSourceRow(
                                source: source,
                                onOpen: { selectedCatalog = source },
                                onDelete: source.isCustom
                                    ? { pendingCatalogDeletion = source }
                                    : nil)
                        }

                        ToolActionRow(
                            icon: .link,
                            title: "Add Catalog",
                            subtitle: "Save another secure ebook website"
                        ) {
                            isAddCatalogPresented = true
                        }
                    }

                    toolSection("Experiments") {
                        ToolActionRow(
                            icon: .headphones,
                            title: "Background Playback",
                            subtitle: "Test continuous play with the screen locked"
                        ) {
                            isPlaybackLabPresented = true
                        }
                    }

                    toolSection("Coming Soon") {
                        ToolActionRow(
                            icon: .link,
                            title: "Share Link",
                            subtitle: "Import readable content from a web link",
                            isEnabled: false) {}

                        ToolActionRow(
                            icon: .image,
                            title: "Upload Image",
                            subtitle: "Turn photographed text into a readable page",
                            isEnabled: false) {}
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 132)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $isPlaybackLabPresented) {
            StreamingPlaybackLabView(viewModel: app.tts)
        }
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
            .font(.custom("EBGaramond-Italic", size: 48, relativeTo: .largeTitle))
            .fontWeight(.medium)
            .foregroundStyle(Color.appPrimaryText)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(AppTextStyle.sectionTitle.font)
                .foregroundStyle(Color.appPrimaryText)

            VStack(spacing: 8) {
                content()
            }
        }
    }
}

private struct ToolActionRow: View {
    let icon: LucideIconName
    let title: String
    let subtitle: String
    var isEnabled = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                rowIcon

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AppTextStyle.rowTitle.font)
                        .foregroundStyle(Color.appPrimaryText)
                    Text(subtitle)
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(Color.appSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isEnabled {
                    LucideIcon(.chevronRight, size: 16, color: Color.appTertiaryText)
                } else {
                    Text("Soon")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appTertiaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.appBackground.opacity(0.8), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.appSecondaryBackground.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.pressOpacity)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.52)
    }

    private var rowIcon: some View {
        Circle()
            .fill(Color.appBackground)
            .frame(width: 42, height: 42)
            .overlay { LucideIcon(icon, size: 18, color: Color.appPrimaryText) }
    }
}

private struct CatalogSourceRow: View {
    let source: CatalogSource
    let onOpen: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(Color.appBackground)
                        .frame(width: 42, height: 42)
                        .overlay {
                            LucideIcon(.book, size: 18, color: Color.appPrimaryText)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name)
                            .font(AppTextStyle.rowTitle.font)
                            .foregroundStyle(Color.appPrimaryText)
                            .lineLimit(1)
                        Text(source.subtitle)
                            .font(AppTextStyle.label.font)
                            .foregroundStyle(Color.appSecondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                Menu {
                    Button("Delete Catalog", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(source.name)")
            } else {
                LucideIcon(.chevronRight, size: 16, color: Color.appTertiaryText)
                    .frame(width: 36, height: 44)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.appSecondaryBackground.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 18))
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
