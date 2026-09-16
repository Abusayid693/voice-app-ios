import SwiftUI

/// Read-only view of a saved generation's original text — reached via the
/// pen icon swipe action on a Library row. Not editable: this is purely
/// "what did I actually write for this one", not a text editor.
struct GenerationTextSheet: View {
    let generation: SavedGeneration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(generation.text)
                    .appText(.reading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Original Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    GenerationTextSheet(
        generation: SavedGeneration(
            id: UUID(), text: "Hello from FluidAudio!", engine: .kokoroAne, voiceName: "af_heart",
            createdAt: Date()))
}
