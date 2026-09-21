import SwiftUI

/// The ⋯ menu reached from `ChapterPlayerView`'s nav bar. All preferences
/// are persisted by the presenter and passed down as bindings, so the sheet
/// has no storage of its own to fall out of sync with.
struct ChapterPlayerOptionsSheet: View {
    @Binding var keepScreenOn: Bool
    @Binding var showFloatingPlayer: Bool
    @Binding var autoScrollEnabled: Bool
    @Binding var wordHighlightEnabled: Bool
    @Binding var fontSize: ReaderFontSize
    @Binding var theme: ReaderTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                row(
                    title: "Keep screen on",
                    subtitle: "Prevents the screen from auto-locking on this page",
                    isOn: $keepScreenOn)
                row(
                    title: "Floating player",
                    subtitle: "Show the playback controls floating over the text",
                    isOn: $showFloatingPlayer)
                row(
                    title: "Auto-scroll",
                    subtitle: "Follow the currently playing text",
                    isOn: $autoScrollEnabled)
                row(
                    title: "Word highlighting",
                    subtitle: "Highlight each word as it's spoken",
                    isOn: $wordHighlightEnabled)
                pickerCard(title: "Font size") {
                    HStack(spacing: 10) {
                        ForEach(ReaderFontSize.allCases) { option in
                            fontSizePreview(option)
                        }
                    }
                }
                pickerCard(title: "Theme") {
                    VStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { option in
                            themePreview(option)
                        }
                    }
                }
            }
            .padding()
        }
        .background(theme.background.ignoresSafeArea())
        .presentationBackground(theme.background)
        .presentationDetents([.medium, .large])
        .preferredColorScheme(theme.colorScheme)
        .animation(.easeInOut(duration: 0.18), value: theme)
    }

    private func row(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(theme.primaryText)
                Text(subtitle)
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .tint(theme.controlAccent)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.controlBackground))
    }

    private func pickerCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(theme.primaryText)
            content()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.controlBackground))
    }

    private func themePreview(_ option: ReaderTheme) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                theme = option
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    Text("Follow each")
                    previewHighlight("spoken", theme: option)
                    Text("word")
                }
                HStack(spacing: 3) {
                    Text("and let the")
                    previewHighlight("story", theme: option)
                    Text("unfold.")
                }
            }
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(option.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .padding(.trailing, 30)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(option.background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        theme == option ? option.controlAccent : option.primaryText.opacity(0.12),
                        lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if theme == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(option.highlightedText, option.controlAccent)
                        .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) theme")
        .accessibilityAddTraits(theme == option ? .isSelected : [])
    }

    private func fontSizePreview(_ option: ReaderFontSize) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                fontSize = option
            }
        } label: {
            VStack(spacing: 3) {
                Text("Read")
                Text("along")
            }
            .font(option.font)
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        fontSize == option ? theme.controlAccent : theme.primaryText.opacity(0.12),
                        lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if fontSize == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.highlightedText, theme.controlAccent)
                        .padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) font size")
        .accessibilityAddTraits(fontSize == option ? .isSelected : [])
    }

    private func previewHighlight(_ text: String, theme: ReaderTheme) -> some View {
        Text(text)
            .foregroundStyle(theme.highlightedText)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                theme.wordHighlightBackground,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

#Preview {
    Text("Host")
        .sheet(isPresented: .constant(true)) {
            ChapterPlayerOptionsSheet(
                keepScreenOn: .constant(false),
                showFloatingPlayer: .constant(true),
                autoScrollEnabled: .constant(true),
                wordHighlightEnabled: .constant(true),
                fontSize: .constant(.medium),
                theme: .constant(.carbon))
        }
}
