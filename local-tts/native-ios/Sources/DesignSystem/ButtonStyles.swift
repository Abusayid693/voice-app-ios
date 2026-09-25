import SwiftUI

/// The app's shared button chrome styles — each owns its own label
/// font/color and background so no call site composes button chrome by
/// hand. Usage: `.buttonStyle(.primary)`, `.buttonStyle(.secondary)`,
/// `.buttonStyle(.ghost)`. `.primary` is full-width by design (it's used
/// only for standalone bottom-of-screen CTAs); `.secondary` sizes to its
/// content, since its real call sites (a "Download" row action, a compact
/// inline control) sit inline next to other content, not alone.
private let buttonLabelFont: Font = .system(size: 16, weight: .medium)

/// Filled black CTA — the app's main action (Generate, …).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(buttonLabelFont)
            .foregroundStyle(Color.primaryButtonText)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.primaryButtonBackground)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Filled warm-grey CTA — a real alternative to `.primary`, not a dimmed
/// copy of it (Download, Play/Re-record, …). Content-sized, not
/// full-width — see this file's header comment for why.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(buttonLabelFont)
            .foregroundStyle(Color.secondaryButtonText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondaryButtonBackground)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Transparent "liquid glass" CTA — frosted-material fill, no opaque
/// background. Real Liquid Glass (`.glassEffect()`) is iOS 26+ only; this
/// app's deployment target is iOS 17, so the same frosted look is built
/// from `.ultraThinMaterial` + a subtle stroke instead (same approach
/// OpenSourceCard's own card already uses for the same reason). No
/// current call site — kept for the next full-bleed frosted CTA (a real
/// `Button` only; a `Link` can't take a `ButtonStyle`).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(buttonLabelFont)
            .foregroundStyle(Color.ghostButtonText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}
