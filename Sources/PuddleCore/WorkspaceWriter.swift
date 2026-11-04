import Foundation

public struct WorkspaceSave: Sendable {
    public let snapshot: AppSnapshot
    public let revision: UInt64
}
public struct WorkspaceWriteFailure: LocalizedError {
    public let underlying: Error
    public let lastSaved: WorkspaceSave?
    public var errorDescription: String? { underlying.localizedDescription }
}
public struct MeetingRecoverySave: Sendable {
    public let values: [MeetingCaptureRecovery]
    public let revision: UInt64
}

/// Serializes disk work off the main actor. While a write is running, callers
/// share the next write of the newest snapshot. A failure rejects the entire
/// pending batch so an unacknowledged edit cannot later overwrite a rollback.
public actor WorkspaceWriter {
    private let persistence: any SnapshotPersistence
    private var pending: WorkspaceSave?
    private var lastSaved: WorkspaceSave?
    private var latestRevision: UInt64 = 0
    private var active: WorkspaceSave?
    private var activeWaiters: [CheckedContinuation<WorkspaceSave, Error>] = []
    private var pendingEpoch: UUID?
    private var rejectedEpochs = Set<UUID>()
    private var waiters: [CheckedContinuation<WorkspaceSave, Error>] = []
    private var running = false
    private var checkpointSave: MeetingRecoverySave?
    var pendingRequestCount: Int { waiters.count }
    public init(_ persistence: any SnapshotPersistence) { self.persistence = persistence }

    public func load() async throws -> SnapshotLoadResult {
        let persistence = persistence
        return try await Task.detached(priority: .utility) {
            let loaded = try persistence.loadResult()
            let snapshot = loaded.snapshot.mergingMeetingRecoveries(try persistence.loadMeetingRecoveries())
            return SnapshotLoadResult(snapshot: snapshot, notice: loaded.notice)
        }.value
    }

    public func save(_ snapshot: AppSnapshot, revision: UInt64, epoch: UUID? = nil) async throws -> WorkspaceSave {
        try await withCheckedThrowingContinuation { continuation in
            if let epoch, rejectedEpochs.contains(epoch) {
                continuation.resume(throwing: WorkspaceWriteFailure(underlying: PuddleError("A previous write failed; retry the edit after rollback."), lastSaved: lastSaved)); return
            }
            if revision > latestRevision {
                latestRevision = revision; pending = WorkspaceSave(snapshot: snapshot, revision: revision); pendingEpoch = epoch
            } else if pending == nil, let active, active.revision >= revision {
                activeWaiters.append(continuation); return
            } else if pending == nil, let lastSaved, lastSaved.revision >= revision {
                continuation.resume(returning: lastSaved); return
            }
            if pending == nil {
                continuation.resume(throwing: WorkspaceWriteFailure(underlying: PuddleError("This write belongs to a failed batch."), lastSaved: lastSaved)); return
            }
            waiters.append(continuation)
            if !running { running = true; Task { await drain() } }
        }
    }

    /// Actor-isolated and small: checkpoints write only recovery text. The
    /// persistence implementation serializes this with full saves using its lock.
    @discardableResult public func checkpoint(_ values: [MeetingCaptureRecovery], revision: UInt64 = 0) throws -> MeetingRecoverySave {
        if let checkpointSave, revision > 0, checkpointSave.revision >= revision { return checkpointSave }
        do {
            try persistence.saveMeetingRecoveries(values)
            let saved = MeetingRecoverySave(values: values, revision: revision)
            checkpointSave = saved
            return saved
        }
        catch { PuddleDiagnostics.failure(.persistence, "Save meeting recovery", error); throw error }
    }

    private func drain() async {
        while let snapshot = pending {
            active = snapshot; activeWaiters = waiters
            let epoch = pendingEpoch
            pending = nil; pendingEpoch = nil; waiters = []
            let persistence = persistence
            do {
                try await Task.detached(priority: .utility) { try persistence.save(snapshot.snapshot) }.value
                lastSaved = snapshot
                for waiter in activeWaiters { waiter.resume(returning: snapshot) }
                active = nil; activeWaiters = []
            } catch {
                PuddleDiagnostics.failure(.persistence, "Save workspace", error)
                if let epoch { rejectedEpochs.insert(epoch) }
                if let pendingEpoch { rejectedEpochs.insert(pendingEpoch) }
                let rejected = activeWaiters + waiters
                active = nil; activeWaiters = []; pending = nil; pendingEpoch = nil; waiters = []; running = false
                for waiter in rejected { waiter.resume(throwing: WorkspaceWriteFailure(underlying: error, lastSaved: lastSaved)) }
                return
            }
        }
        running = false
    }
}

extension AppSnapshot {
    /// Sidecar records cannot revive deleted, applied or explicitly dismissed text.
    public func mergingMeetingRecoveries(_ values: [MeetingCaptureRecovery]) -> AppSnapshot {
        var result = self
        let recoveries = Dictionary((meetingCaptureRecoveries + values).map { ($0.noteID, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        result.meetingCaptureRecoveries = recoveries.values.filter { recovery in
            guard let note = meetings.first(where: { $0.id == recovery.noteID }) else { return false }
            return recovery.updatedAt > (meetingRecoveryDismissals[recovery.noteID] ?? .distantPast) && !note.transcript.contains(recovery.text)
        }.sorted { $0.updatedAt < $1.updatedAt }
        return result
    }
}
