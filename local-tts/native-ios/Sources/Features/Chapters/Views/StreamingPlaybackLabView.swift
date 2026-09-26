import LucideSwift
import SwiftUI

/// The harness for the background-playback experiment: paste a long text, press
/// play, lock the phone, and see whether it keeps going.
///
/// Everything on screen is diagnostics. The numbers that matter are the
/// synthesis lead (how many chunks are ready beyond the one playing) and
/// whether it holds while the screen is off — if the lead ever reaches zero the
/// audio stalls, and a long enough stall gets the app suspended.
struct StreamingPlaybackLabView: View {
    @ObservedObject var viewModel: TTSViewModel
    @StateObject private var lab: StreamingPlaybackLab

    @State private var text = ""

    init(viewModel: TTSViewModel) {
        self.viewModel = viewModel
        _lab = StateObject(wrappedValue: StreamingPlaybackLab(
            synthesis: ChapterSynthesisService(kokoroServices: viewModel.kokoroServices)))
    }

    var body: some View {
        VStack(spacing: 16) {
            editor
            readout
            controls
            eventLog
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Background Playback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onDisappear { lab.stop() }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(
                    Color.appSecondaryBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if text.isEmpty {
                Text("Paste ~2000 words here")
                    .appText(.body)
                    .foregroundStyle(Color.appSecondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Color.appPrimaryText)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Status", lab.status)
            row("Words", "\(wordCount)")
            row(
                "Chunk",
                lab.totalChunks > 0 ? "\(lab.playingChunk + 1) of \(lab.totalChunks)" : "—")
            // The number to watch while locked. Zero means playback has caught
            // up with synthesis and the audio is about to go silent.
            row("Ready ahead", lab.totalChunks > 0 ? "\(readyAhead)" : "—")
            row("Elapsed", "\(Self.time(lab.elapsed)) / \(Self.time(lab.estimatedDuration))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.appSecondaryBackground,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .appText(.label)
                .foregroundStyle(Color.appSecondaryText)
            Spacer()
            Text(value)
                .appText(.label)
                .foregroundStyle(Color.appPrimaryText)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(lab.totalChunks == 0 ? "Play" : (lab.isPlaying ? "Pause" : "Resume")) {
                if lab.totalChunks == 0 {
                    lab.start(text: text, voice: viewModel.kokoroVoice)
                } else {
                    lab.togglePlayPause()
                }
            }
            .buttonStyle(.primary)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Stop") { lab.stop() }
                .buttonStyle(.secondary)
                .disabled(lab.totalChunks == 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The actual output of the experiment — read this after unlocking to see
    /// whether synthesis kept running while the screen was off.
    private var eventLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lab.events.enumerated()), id: \.offset) { index, event in
                        Text(event)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                event.contains("STARVED") || event.contains("FAILED")
                                    ? Color.red : Color.appSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 220)
            .background(
                Color.appSecondaryBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: lab.events.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var readyAhead: Int {
        max(0, lab.synthesisedChunks - lab.playingChunk - 1)
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
