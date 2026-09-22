import SwiftUI

/// Shared Home-header selector. Its matched-geometry pill intentionally lives
/// inside the selector so it can animate without coupling either Home mode to
/// the other mode's content or scroll position.
struct HomeModeSwitcher: View {
    @Binding var selection: HomeMode
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeMode.allCases) { mode in
                Button {
                    withAnimation(.smooth(duration: 0.28, extraBounce: 0.05)) {
                        selection = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode == selection ? selection.primaryText : selection.primaryText.opacity(0.58))
                        .frame(width: 78, height: 32)
                        .background {
                            if mode == selection {
                                Capsule()
                                    .fill(selection == .studio ? Color.appSecondaryBackground : Color.white.opacity(0.86))
                                    .matchedGeometryEffect(id: "home-mode-selection", in: selectionNamespace)
                                    .shadow(color: .black.opacity(selection == .studio ? 0.14 : 0.08), radius: 3, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.title) mode")
                .accessibilityAddTraits(mode == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(selection.primaryText.opacity(selection == .studio ? 0.12 : 0.10), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home mode")
    }
}
