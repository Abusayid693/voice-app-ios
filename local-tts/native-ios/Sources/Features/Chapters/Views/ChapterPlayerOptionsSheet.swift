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
    @Binding var fontFamily: ReaderFontFamily
    @Binding var theme: ReaderTheme

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .root

    private enum Page: Equatable {
        case root
        case controls
        case font

        var title: String {
            switch self {
            case .root: return "Reader options"
            case .controls: return "Controls"
            case .font: return "Font"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                pageContent
                    .padding(.horizontal, 16)
                    .padding(.top, 70)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            // Content scrolls underneath this material so it softly blurs
            // instead of meeting a solid header or divider line.
            header
                .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        // Match VoicePreviewSheet: the system sheet is invisible and this
        // view draws the rounded, themed sheet card itself.
        .presentationBackground(.clear)
        // One detent keeps the sheet at its initial height. All overflow is
        // handled by the ScrollView above rather than expanding the sheet.
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .preferredColorScheme(theme.colorScheme)
        .animation(.easeInOut(duration: 0.18), value: theme)
    }

    private var header: some View {
        ZStack {
            Text(page.title)
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            HStack {
                Button {
                    if page == .root {
                        dismiss()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            page = .root
                        }
                    }
                } label: {
                    Image(systemName: page == .root ? "xmark" : "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.optionsAccent)
                        .frame(width: 36, height: 36)
                        .background(
                            theme.primaryText.opacity(theme.colorScheme == .dark ? 0.12 : 0.07),
                            in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page == .root ? "Close" : "Back")

                Spacer()
            }
        }
        .frame(height: 54)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .root:
            rootContent
        case .controls:
            controlsContent
        case .font:
            fontContent
        }
    }

    private var rootContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            navigationRow(
                title: "Controls",
                subtitle: "Playback, scrolling, and highlighting",
                systemImage: "slider.horizontal.3"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    page = .controls
                }
            }

            navigationRow(
                title: "Font",
                subtitle: "\(fontFamily.title) · \(fontSize.title)",
                systemImage: "textformat"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    page = .font
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
    }

    private var controlsContent: some View {
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
        }
    }

    private var fontContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerCard(title: "Text size") {
                HStack(spacing: 10) {
                    ForEach(ReaderFontSize.allCases) { option in
                        fontSizePreview(option)
                    }
                }
            }

            pickerCard(title: "Typeface") {
                VStack(spacing: 10) {
                    ForEach(ReaderFontFamily.allCases) { option in
                        fontFamilyPreview(option)
                    }
                }
            }
        }
    }

    private func navigationRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.optionsAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTextStyle.rowTitle.font)
                        .foregroundStyle(theme.primaryText)
                    Text(subtitle)
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.controlBackground))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
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
                        theme == option ? option.optionsAccent : option.primaryText.opacity(0.12),
                        lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if theme == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(option.highlightedText, option.optionsAccent)
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
            .font(option.font(family: fontFamily))
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
                        fontSize == option ? theme.optionsAccent : theme.primaryText.opacity(0.12),
                        lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if fontSize == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.highlightedText, theme.optionsAccent)
                        .padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) font size")
        .accessibilityAddTraits(fontSize == option ? .isSelected : [])
    }

    private func fontFamilyPreview(_ option: ReaderFontFamily) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                fontFamily = option
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.title)
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(theme.secondaryText)
                    Text("The story continues…")
                        .font(option.font(size: 19))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if fontFamily == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.highlightedText, theme.optionsAccent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        fontFamily == option ? theme.optionsAccent : theme.primaryText.opacity(0.12),
                        lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) typeface")
        .accessibilityAddTraits(fontFamily == option ? .isSelected : [])
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
                fontFamily: .constant(.sfProText),
                theme: .constant(.carbon))
        }
}
