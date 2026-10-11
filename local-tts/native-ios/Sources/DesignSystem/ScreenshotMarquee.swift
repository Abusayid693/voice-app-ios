import SwiftUI
import UIKit

/// An infinite, edge-to-edge horizontal scroll of the app's bundled preview
/// screenshots. Built for About's opening visual (`AboutView.swift`) and
/// promoted here once Stats' empty-day detail needed the identical marquee
/// at a smaller size — see CLAUDE.md's `Shared/` guidance: promote on a real
/// second consumer, not preemptively. Every sizing knob is a parameter with
/// About's own original values as the defaults, so that call site is
/// unchanged.
///
/// A `UIViewRepresentable` over a `CABasicAnimation`, not a SwiftUI
/// `TimelineView`: the strip never stops for as long as the view is visible,
/// and Core Animation runs that on the render server with no per-frame
/// SwiftUI re-evaluation, where a `TimelineView` would redraw this way for
/// the view's entire lifetime.
struct ScreenshotMarquee: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var cardWidth: CGFloat = 132 * 0.9
    var cardHeight: CGFloat = 286 * 0.9
    var spacing: CGFloat = 14
    var cornerRadius: CGFloat = 22 * 0.9
    /// Clearance above/below the cards so their drop shadow isn't clipped by
    /// the viewport frame.
    var verticalPadding: CGFloat = 36
    var duration: TimeInterval = 48

    private var viewportHeight: CGFloat { cardHeight + verticalPadding }

    var body: some View {
        ScreenshotMarqueeRepresentable(
            reduceMotion: reduceMotion, cardWidth: cardWidth, cardHeight: cardHeight,
            spacing: spacing, cornerRadius: cornerRadius, duration: duration)
            .frame(height: viewportHeight)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("App preview gallery")
    }
}

private struct ScreenshotMarqueeRepresentable: UIViewRepresentable {
    let reduceMotion: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let spacing: CGFloat
    let cornerRadius: CGFloat
    let duration: TimeInterval

    func makeUIView(context: Context) -> ScreenshotMarqueeView {
        let view = ScreenshotMarqueeView(
            cardWidth: cardWidth, cardHeight: cardHeight, spacing: spacing,
            cornerRadius: cornerRadius, duration: duration)
        view.setReduceMotion(reduceMotion)
        return view
    }

    func updateUIView(_ uiView: ScreenshotMarqueeView, context: Context) {
        uiView.setReduceMotion(reduceMotion)
    }
}

private final class ScreenshotMarqueeView: UIView {
    private static let assets = [
        "AboutPreviewShelf",
        "AboutPreviewBookDetail",
        "AboutPreviewReader",
        "AboutPreviewNowPlaying",
        "AboutPreviewStats",
        "AboutPreviewLibrary",
    ]
    private static let animationKey = "screenshotMarquee.translation"

    private let cardWidth: CGFloat
    private let cardHeight: CGFloat
    private let spacing: CGFloat
    private let cornerRadius: CGFloat
    private let duration: TimeInterval
    private let loopWidth: CGFloat

    private let trackView = UIView()
    private var reduceMotion = false

    init(
        cardWidth: CGFloat, cardHeight: CGFloat, spacing: CGFloat, cornerRadius: CGFloat,
        duration: TimeInterval
    ) {
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.duration = duration
        self.loopWidth = CGFloat(Self.assets.count) * (cardWidth + spacing)
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        trackView.backgroundColor = .clear
        trackView.isUserInteractionEnabled = false
        addSubview(trackView)
        buildCards()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = CGRect(
            x: 0,
            y: (bounds.height - cardHeight) / 2,
            width: loopWidth * 2,
            height: cardHeight)
        startAnimationIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            trackView.layer.removeAnimation(forKey: Self.animationKey)
        } else {
            setNeedsLayout()
            layoutIfNeeded()
            startAnimationIfNeeded()
        }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled || trackView.layer.animation(forKey: Self.animationKey) == nil
        else { return }
        reduceMotion = enabled
        trackView.layer.removeAnimation(forKey: Self.animationKey)
        trackView.layer.transform = CATransform3DIdentity
        if !enabled {
            startAnimationIfNeeded()
        }
    }

    private func buildCards() {
        for sequence in 0..<2 {
            for (index, asset) in Self.assets.enumerated() {
                let x = CGFloat(sequence * Self.assets.count + index) * (cardWidth + spacing)
                let card = UIView(frame: CGRect(x: x, y: 0, width: cardWidth, height: cardHeight))
                card.isUserInteractionEnabled = false
                card.layer.shadowColor = UIColor.black.cgColor
                card.layer.shadowOpacity = 0.14
                card.layer.shadowRadius = 12
                card.layer.shadowOffset = CGSize(width: 0, height: 7)
                card.layer.shadowPath = UIBezierPath(
                    roundedRect: card.bounds, cornerRadius: cornerRadius
                ).cgPath

                let imageView = UIImageView(frame: card.bounds)
                imageView.image = UIImage(named: asset)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = cornerRadius
                imageView.layer.cornerCurve = .continuous
                imageView.layer.borderColor = UIColor.black.withAlphaComponent(0.10).cgColor
                imageView.layer.borderWidth = 0.75
                card.addSubview(imageView)
                trackView.addSubview(card)
            }
        }
    }

    private func startAnimationIfNeeded() {
        guard window != nil,
            !reduceMotion,
            trackView.layer.animation(forKey: Self.animationKey) == nil
        else { return }

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -loopWidth
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = true
        trackView.layer.add(animation, forKey: Self.animationKey)
    }
}
