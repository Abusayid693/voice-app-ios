import SwiftUI

/// True top-to-bottom variable blur shared by sheet and reader headers.
struct ProgressiveHeaderBlur: View {
    var body: some View {
        VariableBlurView(maxBlurRadius: 12, direction: .blurredTopClearBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
