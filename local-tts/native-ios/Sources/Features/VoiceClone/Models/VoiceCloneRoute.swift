import Foundation

/// Push destinations within CreateVoiceSheet's own NavigationStack — a
/// small route enum scoped to this one flow, not a second global router
/// (per CLAUDE.md's navigation guidance).
enum VoiceCloneRoute: Hashable {
    case instantClone
    case upload
}
