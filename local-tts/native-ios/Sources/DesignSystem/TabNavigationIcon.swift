import SwiftUI

/// Code-native counterparts to the four tab icons. Outline and selected
/// artwork share the same 24×24 geometry, so selection changes the treatment
/// without substituting a different symbol or changing its layout bounds.
enum TabNavigationIconKind: Hashable {
    case shelf
    case tools
    case library
    case stats
}

struct TabNavigationIcon: View {
    let kind: TabNavigationIconKind
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var continuousRotation: Double = 0

    var body: some View {
        ZStack {
            Canvas { context, size in
                prepare(&context, for: size)
                drawOutline(in: &context)
            }
            .opacity(isSelected ? 0 : 1)

            Canvas { context, size in
                prepare(&context, for: size)
                drawFilled(in: &context)
            }
            .opacity(isSelected ? 1 : 0)
        }
        .rotationEffect(.degrees(kind == .stats ? continuousRotation : 0))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
        .task(id: reduceMotion) {
            startContinuousRotation()
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func startContinuousRotation() {
        guard kind == .stats, !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { continuousRotation = 0 }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { continuousRotation = 0 }
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            continuousRotation = 360
        }
    }

    private var outlineStyle: StrokeStyle {
        StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    }

    private func prepare(_ context: inout GraphicsContext, for size: CGSize) {
        let scale = min(size.width, size.height) / 24
        context.translateBy(
            x: (size.width - 24 * scale) / 2,
            y: (size.height - 24 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
    }

    private func drawOutline(in context: inout GraphicsContext) {
        switch kind {
        case .shelf:
            context.stroke(Self.doorSlab, with: .foreground, style: outlineStyle)
            context.stroke(Self.doorJamb, with: .foreground, style: outlineStyle)
            context.stroke(Self.doorHandle, with: .foreground, style: outlineStyle)

        case .tools:
            context.stroke(Self.visionGoggles, with: .foreground, style: outlineStyle)

        case .library:
            context.stroke(Self.libraryBasket, with: .foreground, style: outlineStyle)
            context.stroke(Self.libraryUpperHandle, with: .foreground, style: outlineStyle)
            context.stroke(Self.libraryLowerHandle, with: .foreground, style: outlineStyle)

        case .stats:
            for segment in Self.statsSegments {
                context.stroke(segment, with: .foreground, style: outlineStyle)
            }
        }
    }

    private func drawFilled(in context: inout GraphicsContext) {
        switch kind {
        case .shelf:
            var slabWithHandleCutout = Self.doorSlab
            slabWithHandleCutout.addRoundedRect(
                in: CGRect(x: 10.75, y: 9.4, width: 1.8, height: 4.2),
                cornerSize: CGSize(width: 0.9, height: 0.9))
            context.fill(
                slabWithHandleCutout,
                with: .foreground,
                style: FillStyle(eoFill: true))
            context.stroke(
                Self.doorJamb,
                with: .foreground,
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        case .tools:
            context.fill(Self.visionGoggles, with: .foreground)

        case .library:
            context.fill(Self.libraryBasket, with: .foreground)
            let selectedHandle = StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
            context.stroke(Self.libraryUpperHandle, with: .foreground, style: selectedHandle)
            context.stroke(Self.libraryLowerHandle, with: .foreground, style: selectedHandle)

        case .stats:
            for segment in Self.statsSegments {
                context.stroke(segment, with: .foreground, style: outlineStyle)
            }
        }
    }

    private static var doorSlab: Path {
        var path = Path()
        path.move(to: CGPoint(x: 4.2, y: 5.3))
        path.addCurve(
            to: CGPoint(x: 5.8, y: 3.6),
            control1: CGPoint(x: 4.2, y: 4.5),
            control2: CGPoint(x: 4.8, y: 3.9))
        path.addLine(to: CGPoint(x: 14.2, y: 1.3))
        path.addCurve(
            to: CGPoint(x: 16.7, y: 3.6),
            control1: CGPoint(x: 15.6, y: 0.9),
            control2: CGPoint(x: 16.7, y: 2))
        path.addLine(to: CGPoint(x: 16.7, y: 20.5))
        path.addCurve(
            to: CGPoint(x: 14.2, y: 22.8),
            control1: CGPoint(x: 16.7, y: 22.1),
            control2: CGPoint(x: 15.6, y: 23.2))
        path.addLine(to: CGPoint(x: 5.8, y: 20.5))
        path.addCurve(
            to: CGPoint(x: 4.2, y: 18.8),
            control1: CGPoint(x: 4.8, y: 20.2),
            control2: CGPoint(x: 4.2, y: 19.6))
        path.closeSubpath()
        return path
    }

    private static var doorJamb: Path {
        var path = Path()
        path.move(to: CGPoint(x: 19, y: 3.7))
        path.addCurve(
            to: CGPoint(x: 21.5, y: 6.2),
            control1: CGPoint(x: 20.5, y: 3.7),
            control2: CGPoint(x: 21.5, y: 4.7))
        path.addLine(to: CGPoint(x: 21.5, y: 17.8))
        path.addCurve(
            to: CGPoint(x: 19, y: 20.3),
            control1: CGPoint(x: 21.5, y: 19.3),
            control2: CGPoint(x: 20.5, y: 20.3))
        return path
    }

    private static var doorHandle: Path {
        var path = Path()
        path.move(to: CGPoint(x: 11.65, y: 10.5))
        path.addLine(to: CGPoint(x: 11.65, y: 12.5))
        return path
    }

    private static var visionGoggles: Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.1, y: 7.6))
        path.addCurve(
            to: CGPoint(x: 6.7, y: 4.1),
            control1: CGPoint(x: 2.7, y: 5.2),
            control2: CGPoint(x: 4.1, y: 4.1))
        path.addCurve(
            to: CGPoint(x: 17.3, y: 4.1),
            control1: CGPoint(x: 10.2, y: 3.6),
            control2: CGPoint(x: 13.8, y: 3.6))
        path.addCurve(
            to: CGPoint(x: 21.9, y: 7.6),
            control1: CGPoint(x: 19.9, y: 4.1),
            control2: CGPoint(x: 21.3, y: 5.2))
        path.addCurve(
            to: CGPoint(x: 17.5, y: 16.6),
            control1: CGPoint(x: 23, y: 12),
            control2: CGPoint(x: 21, y: 16.2))
        path.addCurve(
            to: CGPoint(x: 12, y: 14),
            control1: CGPoint(x: 14.7, y: 16.9),
            control2: CGPoint(x: 13.7, y: 14))
        path.addCurve(
            to: CGPoint(x: 6.5, y: 16.6),
            control1: CGPoint(x: 10.3, y: 14),
            control2: CGPoint(x: 9.3, y: 16.9))
        path.addCurve(
            to: CGPoint(x: 2.1, y: 7.6),
            control1: CGPoint(x: 3, y: 16.2),
            control2: CGPoint(x: 1, y: 12))
        path.closeSubpath()
        return path
    }

    private static var libraryBasket: Path {
        var path = Path()
        path.move(to: CGPoint(x: 3.1, y: 10.8))
        path.addCurve(
            to: CGPoint(x: 5.3, y: 9.2),
            control1: CGPoint(x: 3.5, y: 9.8),
            control2: CGPoint(x: 4.2, y: 9.2))
        path.addLine(to: CGPoint(x: 18.7, y: 9.2))
        path.addCurve(
            to: CGPoint(x: 20.9, y: 10.8),
            control1: CGPoint(x: 19.8, y: 9.2),
            control2: CGPoint(x: 20.5, y: 9.8))
        path.addCurve(
            to: CGPoint(x: 18.3, y: 20.9),
            control1: CGPoint(x: 21.2, y: 12.3),
            control2: CGPoint(x: 19.5, y: 18.3))
        path.addCurve(
            to: CGPoint(x: 16.4, y: 22),
            control1: CGPoint(x: 17.9, y: 21.6),
            control2: CGPoint(x: 17.3, y: 22))
        path.addLine(to: CGPoint(x: 7.6, y: 22))
        path.addCurve(
            to: CGPoint(x: 5.7, y: 20.9),
            control1: CGPoint(x: 6.7, y: 22),
            control2: CGPoint(x: 6.1, y: 21.6))
        path.addCurve(
            to: CGPoint(x: 3.1, y: 10.8),
            control1: CGPoint(x: 4.5, y: 18.3),
            control2: CGPoint(x: 2.8, y: 12.3))
        path.closeSubpath()
        return path
    }

    private static var libraryUpperHandle: Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.4, y: 4.2))
        path.addLine(to: CGPoint(x: 7.4, y: 2.7))
        path.addCurve(
            to: CGPoint(x: 8.8, y: 1.5),
            control1: CGPoint(x: 7.4, y: 2),
            control2: CGPoint(x: 7.9, y: 1.5))
        path.addLine(to: CGPoint(x: 15.2, y: 1.5))
        path.addCurve(
            to: CGPoint(x: 16.6, y: 2.7),
            control1: CGPoint(x: 16.1, y: 1.5),
            control2: CGPoint(x: 16.6, y: 2))
        path.addLine(to: CGPoint(x: 16.6, y: 4.2))
        return path
    }

    private static var libraryLowerHandle: Path {
        var path = Path()
        path.move(to: CGPoint(x: 5.1, y: 7.9))
        path.addLine(to: CGPoint(x: 5.1, y: 6.6))
        path.addCurve(
            to: CGPoint(x: 6.5, y: 5.4),
            control1: CGPoint(x: 5.1, y: 5.9),
            control2: CGPoint(x: 5.6, y: 5.4))
        path.addLine(to: CGPoint(x: 17.5, y: 5.4))
        path.addCurve(
            to: CGPoint(x: 18.9, y: 6.6),
            control1: CGPoint(x: 18.4, y: 5.4),
            control2: CGPoint(x: 18.9, y: 5.9))
        path.addLine(to: CGPoint(x: 18.9, y: 7.9))
        return path
    }

    private static var statsSegments: [Path] {
        stride(from: 0.0, to: 360.0, by: 45.0).map { start in
            var path = Path()
            path.addArc(
                center: CGPoint(x: 12, y: 12),
                radius: 9.5,
                startAngle: .degrees(start + 5),
                endAngle: .degrees(start + 31),
                clockwise: false)
            return path
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach(
            [TabNavigationIconKind.shelf, .tools, .library, .stats],
            id: \.self
        ) { kind in
            VStack(spacing: 12) {
                TabNavigationIcon(kind: kind, isSelected: false)
                    .foregroundStyle(Color.tabInactiveDark)
                TabNavigationIcon(kind: kind, isSelected: true)
                    .foregroundStyle(Color.tabSelected)
            }
            .frame(width: 32, height: 72)
        }
    }
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
