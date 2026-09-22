import SwiftUI

/// Shared Home-header selector. Its matched-geometry pill intentionally lives
/// inside the selector so it can animate without coupling either Home mode to
/// the other mode's content or scroll position.
struct HomeModeSwitcher: View {
    @Binding var selection: HomeMode
    private let foreground: Color?
    private let selectedBackground: Color?
    private let trackBackground: Color?
    @Namespace private var selectionNamespace

    init(
        selection: Binding<HomeMode>,
        foreground: Color? = nil,
        selectedBackground: Color? = nil,
        trackBackground: Color? = nil
    ) {
        _selection = selection
        self.foreground = foreground
        self.selectedBackground = selectedBackground
        self.trackBackground = trackBackground
    }

    private var labelColor: Color { foreground ?? selection.primaryText }
    private var pillColor: Color {
        selectedBackground ?? (selection == .studio ? Color.appSecondaryBackground : Color.white.opacity(0.86))
    }
    private var trackColor: Color {
        trackBackground ?? selection.primaryText.opacity(selection == .studio ? 0.12 : 0.10)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.smooth(duration: 0.28, extraBounce: 0.05)) {
                        selection = mode
                    }
                } label: {
                    Text(title(for: mode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode == selection ? labelColor : labelColor.opacity(0.58))
                        .frame(width: 78, height: 32)
                        .background {
                            if mode == selection {
                                Capsule()
                                    .fill(pillColor)
                                    .matchedGeometryEffect(id: "home-mode-selection", in: selectionNamespace)
                                    .shadow(color: .black.opacity(selection == .studio ? 0.14 : 0.08), radius: 3, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title(for: mode)) mode")
                .accessibilityAddTraits(mode == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(trackColor, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home mode")
    }

    private func title(for mode: HomeMode) -> String {
        switch mode {
        case .studio: "Studio"
        case .reading: "Reading"
        }
    }
}
