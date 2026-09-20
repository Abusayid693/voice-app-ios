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
    // The project's voice — same for every chapter (one text, one voice),
    // shown in the description area so it's clear who's reading before you
    // even tap Play.
    let voiceName: String
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
                playButton

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title).appText(.rowTitle)
                    Text(chapter.preview).appText(.label).lineLimit(1)
                    voiceRow
                }

                Spacer()

                if isKokoro { generateControl }
            }

            if let statusText {
                Text(statusText).appText(.meta)
            }
            if case let .running(done, total) = generationState, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(Color.appPrimaryText)
            }
        }
        .padding(.vertical, 4)
    }

    // Generation feedback ("Generating…"/"Waiting"/a failure message) is
    // its own line rather than replacing the chapter's own description —
    // the description should always describe the chapter, not the
    // transient state of generating its audio.
    private var statusText: String? {
        switch generationState {
        case .running(let done, let total): return "Generating… \(done)/\(total)"
        case .queued: return "Waiting to generate…"
        case .failed(let message): return message
        case nil: return nil
        }
    }

    private var voiceRow: some View {
        HStack(spacing: 6) {
            Image(VoiceCoverArt.assetName(for: voiceName))
                .resizable()
                .scaledToFill()
                .frame(width: 16, height: 16)
                .clipShape(Circle())
            Text(VoiceDisplayName.forCode(voiceName)).appText(.meta)
        }
    }

    private var playButton: some View {
        Button(action: onPlayTapped) {
            ZStack {
                Circle().fill(Color.appSecondaryBackground)
                if isActive && isBuffering {
                    ProgressView()
                } else {
                    LucideIcon(
                        isActive && isPlaying ? .pause : .play, style: .filled, size: 22,
                        color: Color.appPrimaryText)
                }
            }
            .frame(width: 52, height: 52)
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
