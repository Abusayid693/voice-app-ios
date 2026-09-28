import SwiftUI

/// Type or paste text and turn it into a Kokoro reader project — pushed
/// from Tools' "Write a Text" row. Uses the reader's current default voice
/// (`TTSViewModel.kokoroVoice`), same as Add Books does for PDF imports,
/// rather than asking for one up front; the voice can still be changed
/// from the reader itself afterward.
struct WriteTextView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var viewModel: TTSViewModel
    let onSaved: (SavedGeneration) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isSaveEnabled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste or type your text here…")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.appTertiaryText)
                        .padding(.horizontal, 17)
                        .padding(.top, 20)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            Button("Save & Read") { save() }
                .buttonStyle(.primary)
                .disabled(!isSaveEnabled)
                .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Write a Text")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard
            let id = library.save(text: text, engine: .kokoroAne, voiceName: viewModel.kokoroVoice),
            let project = library.project(for: id)
        else { return }
        onSaved(project)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    NavigationStack {
        WriteTextView(library: app.library, viewModel: app.tts) { _ in }
    }
    .preferredColorScheme(.dark)
}
