import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9) of the Kokoro
/// packs, computed from the actual directories they're written to
/// (DiskStorage.directorySize), not an estimate. Reader audio is never
/// persisted (streamed and discarded per session), so there is nothing of
/// its own to break out here.
struct StorageView: View {
    @ObservedObject var packs: VoicePackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var contentRevealed = false

    private let theme = ReaderChromeTheme.dark

    private var kokoroBytes: Int64 {
        guard packs.isKokoroPackReady(.english), let directory = packs.kokoroModelDirectory else {
            return 0
        }
        return DiskStorage.directorySize(at: directory)
    }

    // 0 (not shown as "unknown") while the exact directory hasn't been
    // resolved yet this session — see kokoroMandarinModelDirectory's doc
    // comment. Total below still undercounts in that window.
    private var kokoroMandarinBytes: Int64 {
        guard packs.isKokoroPackReady(.mandarin), let directory = packs.kokoroMandarinModelDirectory
        else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    private var totalBytes: Int64 {
        kokoroBytes + kokoroMandarinBytes
    }

    var body: some View {
        InteractiveGlassBottomSheet(
            theme: theme,
            detents: [.height(300)],
            backgroundStyle: .clearGlass,
            closeAccessibilityLabel: "Close storage",
            contentTopInset: 58,
            onClose: { dismiss() }
        ) { headerInset in
            VStack(alignment: .leading, spacing: 14) {
                Text("Storage")
                    .font(.custom("EBGaramond-Italic", size: 34, relativeTo: .title))
                    .fontWeight(.medium)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(StorageEntranceReveal(
                        isVisible: contentRevealed,
                        index: 0))

                VStack(spacing: 0) {
                    row(title: "Kokoro-ANE pack", bytes: kokoroBytes)
                    divider
                    row(title: "Kokoro-ANE pack (Mandarin)", bytes: kokoroMandarinBytes)
                    divider
                    row(title: "Total", bytes: totalBytes, isTotal: true)
                }
                .padding(.horizontal, 18)
                .modifier(StorageEntranceReveal(
                    isVisible: contentRevealed,
                    index: 1))
            }
            .padding(.horizontal, 18)
            .padding(.top, headerInset)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            contentRevealed = true
        }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { contentRevealed = false }
        }
    }

    private func row(title: String, bytes: Int64, isTotal: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: isTotal ? .semibold : .regular))
                .foregroundStyle(theme.primaryText)
            Spacer()
            Text(DiskStorage.formattedSize(bytes))
                .font(.system(size: 15, weight: isTotal ? .bold : .medium, design: .rounded))
                .foregroundStyle(isTotal ? theme.primaryText : theme.secondaryText)
        }
        .frame(minHeight: 48)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
    }
}

private struct StorageEntranceReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 12)
            .animation(
                isVisible && !reduceMotion
                    ? .easeOut(duration: 0.36).delay(Double(index) * 0.10)
                    : nil,
                value: isVisible)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    StorageView(packs: viewModel.packs)
}
