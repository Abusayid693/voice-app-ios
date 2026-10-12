import SwiftUI
import WebKit

struct CatalogBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CatalogBrowserViewModel

    init(
        source: CatalogSource,
        onImport: @escaping (URL, BookImportFormat) async -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: CatalogBrowserViewModel(source: source, onImport: onImport))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.appBackground.ignoresSafeArea()

            CatalogWebView(webView: viewModel.service.webView)
                .padding(.top, 104)

            VStack(spacing: 8) {
                header

                if viewModel.downloadStatus != .idle {
                    downloadBanner
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { viewModel.start() }
        .onDisappear { viewModel.browserDidDisappear() }
        .alert(
            "Catalog",
            isPresented: Binding(
                get: { viewModel.message != nil },
                set: { if !$0 { viewModel.message = nil } })
        ) {
            Button("OK", role: .cancel) { viewModel.message = nil }
        } message: {
            Text(viewModel.message ?? "")
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.downloadStatus)
    }

    private var header: some View {
        ZStack(alignment: .top) {
            ProgressiveHeaderBlur()
                .frame(height: 104)

            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    controlButton(systemImage: "chevron.left", label: "Back to Tools") {
                        dismiss()
                    }

                    Text(viewModel.source.name)
                        .font(AppEditorialFont.italic(size: 28, relativeTo: .title2))
                        .fontWeight(.medium)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    controlButton(systemImage: "safari", label: "Open in browser") {
                        viewModel.openExternally()
                    }
                }

                HStack(spacing: 8) {
                    controlButton(
                        systemImage: "chevron.backward",
                        label: "Previous page",
                        isEnabled: viewModel.canGoBack,
                        action: viewModel.goBack)
                    controlButton(
                        systemImage: "chevron.forward",
                        label: "Next page",
                        isEnabled: viewModel.canGoForward,
                        action: viewModel.goForward)
                    controlButton(
                        systemImage: "arrow.clockwise",
                        label: "Reload",
                        action: viewModel.reload)

                    Text(viewModel.currentURL?.host() ?? viewModel.source.url.host() ?? "")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if viewModel.isLoading {
                        ProgressView()
                            .tint(Color.appPrimaryText)
                            .controlSize(.small)
                            .accessibilityLabel("Loading catalog")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
        .frame(height: 104)
    }

    @ViewBuilder
    private var downloadBanner: some View {
        HStack(spacing: 12) {
            bannerIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(downloadTitle)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)

                if case let .downloading(_, progress) = viewModel.downloadStatus {
                    ProgressView(value: progress)
                        .tint(Color.appPrimaryText)
                } else {
                    Text(downloadSubtitle)
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if case .downloading = viewModel.downloadStatus {
                Button("Cancel", role: .cancel) { viewModel.cancelDownload() }
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.appPrimaryText)
                    .buttonStyle(.pressOpacity)
            } else if !viewModel.downloadStatus.isActive {
                Button { viewModel.clearDownloadStatus() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.pressOpacity)
                .accessibilityLabel("Dismiss download status")
            }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color.appPrimaryText.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var bannerIcon: some View {
        switch viewModel.downloadStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appPrimaryText)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.tabSelected)
        case .idle, .downloading, .importing:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    private var downloadTitle: String {
        switch viewModel.downloadStatus {
        case .idle: return ""
        case let .downloading(filename, _): return "Downloading \(filename)"
        case let .importing(filename): return "Adding \(filename)"
        case let .success(message): return message
        case .failure: return "Download failed"
        }
    }

    private var downloadSubtitle: String {
        switch viewModel.downloadStatus {
        case .importing: return "Handing this book to My Shelf…"
        case .success: return "You can keep browsing this catalog."
        case let .failure(message): return message
        case .idle, .downloading: return ""
        }
    }

    private func controlButton(
        systemImage: String,
        label: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.appPrimaryText : Color.appTertiaryText)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.pressOpacity)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

private struct CatalogWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
