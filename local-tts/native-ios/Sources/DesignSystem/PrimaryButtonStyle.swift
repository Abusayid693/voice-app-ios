import SwiftUI

/// The app's one shared primary CTA style — light background, black text,
/// full-width, rounded. Deliberately its own real ButtonStyle (not a
/// one-off modifier chain per call site) so it stays visually consistent
/// everywhere it's used. Usage: `.buttonStyle(.primary)`.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appButtonLabel)
            .foregroundStyle(Color.primaryButtonText)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.primaryButtonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
