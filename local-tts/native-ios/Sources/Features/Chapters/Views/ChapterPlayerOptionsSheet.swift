import SwiftUI

/// The ⋯ menu reached from `ChapterPlayerView`'s nav bar. All preferences
/// are persisted by the presenter and passed down as bindings, so the sheet
/// has no storage of its own to fall out of sync with.
struct ChapterPlayerOptionsSheet: View {
    @Binding var keepScreenOn: Bool
    @Binding var showFloatingPlayer: Bool
    @Binding var autoScrollEnabled: Bool
    @Binding var wordHighlightEnabled: Bool
    @Binding var continuousPlaybackEnabled: Bool
    @Binding var fontSize: ReaderFontSize
    @Binding var fontFamily: ReaderFontFamily
    @Binding var theme: ReaderTheme

    @State private var page: Page = .root

    private enum Page: Equatable {
        case root
        case controls
        case font

        var title: String {
            switch self {
            case .root: "Reader Options"
            case .controls: "Controls"
            case .font: "Font"
            }
        }
    }

    // Always dark, independent of `theme` — this sheet's own chrome
    // (rows, toggles, nav buttons) no longer tracks the active reading
    // theme the way it used to. `theme` itself is untouched: the Theme
    // picker below still correctly selects/previews/applies the real
    // reading theme via that binding, and each `themePreview` card already
    // draws from the theme *it* represents (`option.primaryText`/
    // `option.background`), not from `chromeTheme` — so forcing this has
    // no effect on the picker's own accuracy.
    private var chromeTheme: ReaderChromeTheme { .dark }

    var body: some View {
        // `showsDragIndicator` stays at its default (visible) here, unlike
        // this sheet's old `InteractiveGlassBottomSheet` hosting, which hid
        // it — that was safe only because an explicit Close button was
        // always present alongside it. `StandardBottomSheet` has no Close
        // button at all, so hiding the indicator too would leave the root
        // page with no visible way to dismiss.
        StandardBottomSheet(
            title: page.title, detents: [.medium], theme: chromeTheme, onBack: backAction
        ) {
            pageContent
        }
        .animation(.easeInOut(duration: 0.18), value: theme)
    }

    private var backAction: (() -> Void)? {
        guard page != .root else { return nil }
        return {
            withAnimation(.easeInOut(duration: 0.2)) {
                page = .root
            }
        }
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
            row(
                title: "Continue to next page",
                subtitle: "Keep playing into the next page automatically",
                isOn: $continuousPlaybackEnabled)
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
                    .foregroundStyle(chromeTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTextStyle.rowTitle.font)
                        .foregroundStyle(chromeTheme.primaryText)
                    Text(subtitle)
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(chromeTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chromeTheme.secondaryText)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(chromeTheme.controlBackground))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func row(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(chromeTheme.primaryText)
                Text(subtitle)
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(chromeTheme.secondaryText)
            }
        }
        .tint(chromeTheme.accent)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(chromeTheme.controlBackground))
    }

    private func pickerCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(chromeTheme.primaryText)
            content()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(chromeTheme.controlBackground))
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
            .foregroundStyle(chromeTheme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chromeTheme.background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        fontSize == option ? chromeTheme.accent : chromeTheme.border,
                        lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if fontSize == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(chromeTheme.contrastingText, chromeTheme.accent)
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
                        .foregroundStyle(chromeTheme.secondaryText)
                    Text("The story continues…")
                        .font(option.font(size: 19))
                        .foregroundStyle(chromeTheme.primaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if fontFamily == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(chromeTheme.contrastingText, chromeTheme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chromeTheme.background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        fontFamily == option ? chromeTheme.accent : chromeTheme.border,
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
                continuousPlaybackEnabled: .constant(true),
                fontSize: .constant(.medium),
                fontFamily: .constant(.sfProText),
                theme: .constant(.graphite))
        }
}
