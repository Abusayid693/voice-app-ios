import LucideSwift
import SwiftUI

/// Compact, persistent status for an import that continues after the user
/// leaves the file picker. The same job state is restored on the next launch.
struct PDFImportJobCard: View {
    let job: PDFImportJob
    @ObservedObject var manager: PDFImportManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LucideIcon(.fileText, size: 22, color: Color.appPrimaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.sourceFileName).appText(.rowTitle).lineLimit(1)
                    Text(statusText).appText(.label)
                }
                Spacer()
                trailingAction
            }

            if !job.phase.isTerminal {
                ProgressView(value: job.progress)
                    .tint(Color.wordHighlightBackground)
            }

            if let error = job.errorMessage {
                Text(error).appText(.labelDim)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    private var statusText: String {
        if job.phase == .extracting, job.totalPages > 0 {
            return "\(job.phase.title) · \(job.completedPages) of \(job.totalPages) pages"
        }
        return job.phase.title
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch job.phase {
        case .failed:
            HStack(spacing: 8) {
                Button("Retry") { manager.retry(job) }
                    .font(AppTextStyle.label.font)
                Button {
                    manager.delete(job)
                } label: {
                    LucideIcon(.trash, size: 17, color: Color.appSecondaryText)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        case .queued, .validating, .extracting, .chaptering, .finalizing:
            Button {
                manager.cancel(job)
            } label: {
                LucideIcon(.x, size: 18, color: Color.appSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .completed, .cancelled:
            EmptyView()
        }
    }
}
