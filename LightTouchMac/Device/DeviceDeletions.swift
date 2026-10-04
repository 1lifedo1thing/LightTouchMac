// Device deletions in flight, by catalog entry id. Removing a prepared device's tree (its NAND, a read-only
// base) takes seconds, so the work runs off the main actor; the row reads `contains` to show Deleting and refuse
// Start until it's done. Foundation only, so tests/offline/check-sidebar-ui.py runs the real one.

import Foundation

@MainActor final class DeviceDeletions {
    private(set) var ids: Set<String> = []
    /// After an id joins or leaves.
    var onChange: () -> Void = {}

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Marks `id` deleting now and runs `work` on a background thread; the task finishes (or throws) when it has.
    @discardableResult func run(_ id: String, _ work: @escaping @Sendable () throws -> Void) -> Task<Void, Error> {
        ids.insert(id)
        onChange()
        return Task {
            defer { ids.remove(id); onChange() }
            try await Task.detached(priority: .userInitiated) { try work() }.value
        }
    }
}
