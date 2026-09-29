import LucideSwift
import SwiftUI
import UIKit

/// Fixed-size shelf reservation for one active or failed PDF import.
struct PDFImportShelfCover: View {
    @ObservedObject var item: PDFImportShelfItem
    let size: CGSize
    let liftDistance: CGFloat
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    @State private var image: UIImage?
    @State private var isProgressHidden = false
    @State private var isSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            artwork
                .opacity(isSettled ? 1 : 0.5)

            VStack(spacing: 0) {
                ImportProgressBar(progress: item.progress)
                    .frame(height: 2)
                    .opacity(isProgressHidden ? 0 : 1)
                Spacer(minLength: 0)
            }

            if item.isFailed {
                failedControls
            } else if !item.isCompleted {
                cancelButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(Rectangle())
        .offset(y: isSettled ? 0 : -liftDistance)
        .shadow(
            color: .black.opacity(isSettled ? 0.12 : 0.20),
            radius: isSettled ? 4 : 9,
            y: isSettled ? 2 : 6)
        .task(id: item.isCompleted) { await updateCompletionState() }
        .task(id: item.coverURL) { await loadCover() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var artwork: some View {
        ZStack {
            MatrixCoverLoader(seed: item.title, isAnimated: !reduceMotion)
                .opacity(image == nil && !isSettled ? 1 : 0)

            LinearGradient.stablePlaceholder(seed: item.title)
                .overlay {
                    LucideIcon(
                        .book, style: .filled, size: min(size.width, size.height) * 0.26,
                        color: .white.opacity(0.9))
                }
                .opacity(image == nil && isSettled ? 1 : 0)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: image == nil)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            LucideIcon(.x, size: 15, color: .black.opacity(0.82))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel import")
    }

    private var failedControls: some View {
        HStack(spacing: 0) {
            Button(action: onRetry) {
                LucideIcon(.refreshCw, size: 16, color: .black)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Retry import")

            Button(action: onDelete) {
                LucideIcon(.trash, size: 16, color: .black)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Delete failed import")
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
    }

    private var accessibilityLabel: String {
        if item.isFailed { return "\(item.title), import failed" }
        if item.isCompleted { return "\(item.title), ready to read" }
        return "\(item.title), importing, \(Int(item.progress * 100)) percent"
    }

    @MainActor
    private func updateCompletionState() async {
        guard item.isCompleted else {
            isProgressHidden = false
            isSettled = false
            return
        }
        guard !reduceMotion else {
            isProgressHidden = true
            isSettled = true
            return
        }

        withAnimation(.easeOut(duration: 0.18)) { isProgressHidden = true }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            isSettled = true
        }
    }

    @MainActor
    private func loadCover() async {
        guard let url = item.coverURL else {
            image = nil
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)
        }.value
        if reduceMotion {
            image = loaded
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { image = loaded }
        }
    }
}

private struct ImportProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.16))
                Rectangle()
                    .fill(.black.opacity(0.92))
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .animation(.linear(duration: 0.18), value: progress)
        .accessibilityHidden(true)
    }
}

private struct MatrixCoverLoader: View {
    let seed: String
    let isAnimated: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0xFAF8F2),
                    Color(hex: 0xE9E5DC),
                    Color(hex: 0xF4F1EA),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            if isAnimated {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    cells(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                cells(at: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func cells(at time: TimeInterval) -> some View {
        Canvas { context, canvasSize in
            let columns = 5
            let rows = 7
            let gap: CGFloat = 2
            let cellWidth = (canvasSize.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let cellHeight = (canvasSize.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            let seedOffset = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 19)

            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    let delay = Double((index * 7 + Int(seedOffset)) % (rows * columns)) * 0.11
                    let wave = (sin(time * 2.2 - delay) + 1) / 2
                    let opacity = isAnimated ? 0.10 + wave * 0.42 : 0.20 + Double(index % 4) * 0.04
                    let rect = CGRect(
                        x: CGFloat(column) * (cellWidth + gap),
                        y: CGFloat(row) * (cellHeight + gap),
                        width: cellWidth,
                        height: cellHeight)
                    context.opacity = opacity
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(.white))
                }
            }
        }
    }
}
