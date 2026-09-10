import SwiftUI

/// The app's default screen — a consumer-facing "Import" landing page
/// (redesign target: paste/upload/scan/write actions, trending demo rows,
/// a Setup entry point for the two voice packs). Only "Write text" is
/// functional today; the rest are visual placeholders per the current
/// design pass.
struct ImportHomeView: View {
    @ObservedObject var viewModel: TTSViewModel

    private var isFullyDownloaded: Bool {
        viewModel.isKokoroPackReady && viewModel.isPocketPackDownloaded
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    actionGrid
                    trendingVoicesSection
                    whatsTrendingSection
                    createYourOwnBookRow
                    projectsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    setupButton
                }
            }
        }
        .sheet(isPresented: $viewModel.isSetupPresented) {
            SetupSheet(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isWriteTextPresented) {
            WriteTextView(viewModel: viewModel)
        }
    }

    private var setupButton: some View {
        Button {
            viewModel.isSetupPresented = true
        } label: {
            Label("Setup", systemImage: isFullyDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
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

    private var trendingVoicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending voices").font(.headline)
            ForEach(DemoContent.trendingVoices) { voice in
                HStack(spacing: 12) {
                    Circle()
                        .fill(voice.tint.gradient)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).font(.subheadline).bold()
                        Text(voice.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "heart")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
    }

    private var whatsTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's trending").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(DemoContent.trendingBooks) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(book.tint.gradient)
                                .frame(width: 110, height: 150)
                                .overlay {
                                    Image(systemName: "book.closed.fill")
                                        .font(.title)
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            Text(book.title).font(.caption).bold().lineLimit(1)
                            Text(book.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 110)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own book").font(.subheadline).bold()
                    Text("Craft your own story in seconds").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects").font(.headline)
            ForEach(DemoContent.projects) { project in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.subheadline).bold()
                        Text(project.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(project.updatedLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .contentShape(Rectangle())
            }
        }
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
                Text(title)
                    .font(.subheadline)
                    .bold()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 80)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ImportHomeView(viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
