import LucideSwift
import SwiftUI

/// One chapter's row in `ChaptersListView` — a Play button every engine
/// gets, plus a Generate button/progress/cancel that only appears for
/// Kokoro (per-chapter saved audio is Kokoro-only). Visually modeled on
/// `DesignSystem/VoiceCard.swift` (avatar + title/subtitle + trailing
/// button) but kept in this feature, not DesignSystem — it has exactly one
/// consumer and needs chapter-specific state two independent buttons and a
/// generate-progress bar don't fit a primitives-only shared component.
struct ChapterRow: View {
    let chapter: Chapter
    let isKokoro: Bool
    let isGenerated: Bool
    let isActive: Bool
    let isPlaying: Bool
    let isBuffering: Bool
    let generationState: ChapterGenerationState?
    let onPlayTapped: () -> Void
    let onGenerateTapped: () -> Void
    let onCancelGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.appSecondaryBackground)
                    .frame(width: 40, height: 40)
                    .overlay {
                        LucideIcon(.audioWaveform, size: 16, color: Color.appPrimaryText)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title).appText(.rowTitle)
                    Text(subtitle).appText(.label).lineLimit(1)
                }

                Spacer()

                HStack(spacing: 14) {
                    playButton
                    if isKokoro { generateControl }
                }
            }

            if case let .running(done, total) = generationState, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(Color.appPrimaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch generationState {
        case .running(let done, let total): return "Generating… \(done)/\(total)"
        case .queued: return "Waiting to generate…"
        case .failed(let message): return message
        case nil: return isGenerated ? "Generated" : chapter.preview
        }
    }

    private var playButton: some View {
        Button(action: onPlayTapped) {
            if isActive && isBuffering {
                ProgressView()
                    .frame(width: 22, height: 22)
            } else {
                LucideIcon(
                    isActive && isPlaying ? .circlePause : .circlePlay, size: 22,
                    color: Color.appPrimaryText)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var generateControl: some View {
        switch generationState {
        case .queued, .running:
            Button(action: onCancelGenerate) {
                LucideIcon(.x, size: 20, color: Color.appSecondaryText)
            }
            .buttonStyle(.plain)
        case .failed, nil:
            if isGenerated {
                LucideIcon(.circleCheck, size: 20, color: Color.appTertiaryText)
            } else {
                Button(action: onGenerateTapped) {
                    LucideIcon(.circleArrowDown, size: 20, color: Color.appPrimaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
