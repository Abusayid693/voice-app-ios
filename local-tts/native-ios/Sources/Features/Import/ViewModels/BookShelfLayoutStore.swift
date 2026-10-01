import Combine
import Foundation

/// Shelf-only placement; Library's date sorting and import identities stay unchanged.
@MainActor
final class BookShelfLayoutStore: ObservableObject {
    @Published private(set) var rows: [[UUID]]
    @Published var errorMessage: String?
    private let fileURL: URL

    init(fileURL: URL = SavedGeneration.baseDirectory.appendingPathComponent("shelf-layout.json")) {
        self.fileURL = fileURL
        rows = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([[UUID]].self, from: $0) } ?? []
    }

    /// Keep intentional empty shelves. New reservations append, never fill old gaps.
    func layout(for orderedIDs: [UUID]) -> [[UUID]] {
        let valid = Set(orderedIDs)
        var seen = Set<UUID>()
        var result = rows.map { row in
            row.filter { valid.contains($0) && seen.insert($0).inserted }
        }
        for id in orderedIDs where seen.insert(id).inserted {
            let last = result.lastIndex(where: { !$0.isEmpty }) ?? 0
            while result.count <= last { result.append([]) }
            result[last].append(id)
        }
        while result.count > 3 && result.last?.isEmpty == true { result.removeLast() }
        while result.count < 3 { result.append([]) }
        return result
    }

    func synchronize(_ orderedIDs: [UUID]) {
        let updated = layout(for: orderedIDs)
        guard updated != rows else { return }
        _ = persist(updated)
    }

    /// Called only on release. Shelves have no capacity limit or automatic overflow.
    @discardableResult
    func move(_ id: UUID, to shelf: Int, before nextID: UUID?, orderedIDs: [UUID]) -> Bool {
        var updated = layout(for: orderedIDs)
        guard orderedIDs.contains(id), updated.indices.contains(shelf) else { return false }
        for index in updated.indices { updated[index].removeAll { $0 == id } }
        let insertion = nextID.flatMap { updated[shelf].firstIndex(of: $0) } ?? updated[shelf].count
        updated[shelf].insert(id, at: insertion)
        return persist(updated)
    }

    private func persist(_ updated: [[UUID]]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            rows = updated
            return true
        } catch {
            errorMessage = "Couldn't save the shelf arrangement. Please try again."
            return false
        }
    }
}
