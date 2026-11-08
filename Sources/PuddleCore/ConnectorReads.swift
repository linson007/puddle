import Foundation

/// Coalesce identical reads and cap distinct work per provider. Credentials and
/// query keys stay in process memory and never enter diagnostics or persistence.
actor ConnectorReads<Value: Sendable> {
    private var active: [Data: Task<Value, Error>] = [:]
    private(set) var coalescedReadCount = 0
    func run(key: Data, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let existing = active[key] {
            coalescedReadCount += 1
            let value = try await existing.value; try Task.checkCancellation(); return value
        }
        guard active.count < 4 else { throw PuddleError("This provider is busy with other reads. Wait for them to finish, then try again.") }
        let task = Task { try await operation() }
        active[key] = task
        defer { active[key] = nil }
        // One cancelled waiter must not cancel a read shared by another caller.
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }
}
