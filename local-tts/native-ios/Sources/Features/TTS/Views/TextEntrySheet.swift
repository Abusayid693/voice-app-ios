import LucideSwift
import SwiftUI

struct TextEntrySheet: View {
    @Binding var text: String
    var isBusy: Bool
    var onListen: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.title3)
                .padding(4)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: onListen) {
                            if isBusy {
                                ProgressView()
                            } else {
                                Label(title: { Text("Listen") }, icon: { LucideIcon(.audioWaveform, size: 15) })
                            }
                        }
                        .disabled(isBusy || text.isEmpty)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: onClose) {
                            LucideIcon(.x)
                        }
                    }
                }
        }
    }
}
