// Device deletions in flight, by catalog entry id. Removing a prepared device's tree (its NAND, a read-only
// base) takes seconds, so the work runs off the main actor; the row reads `contains` to show Deleting and refuse
// Start until it's done. Foundation only, so tests/offline/check-sidebar-ui.py runs the real one.

import Foundation

@MainActor public final class DeviceDeletions {
    public init() {}
    public private(set) var ids: Set<String> = []
    /// After an id joins or leaves.
    public var onChange: () -> Void = {}

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Marks `id` deleting now, waits for `release` to let go of its session (a shut-down or dead one), then runs
    /// `work` on a background thread; the task finishes (or throws) when it has. A device still running is refused
    /// with DeviceInUse, its storage untouched.
    @discardableResult public func run(
        _ id: String,
        release: @escaping @MainActor () async -> Bool = { true },
        _ work: @escaping @Sendable () throws -> Void
    ) -> Task<Void, Error> {
        ids.insert(id)
        onChange()
        return Task {
            defer {
                ids.remove(id)
                onChange()
            }
            guard await release() else { throw DeviceInUse() }
            try await Task.detached(priority: .userInitiated) { try work() }.value
        }
    }
}

/// A device started again before its storage could change.
public struct DeviceInUse: LocalizedError {
    public init() {}
    public var errorDescription: String? { "This device is running. Shut it down, then try again." }
}
