import Foundation
import XCTest
@testable import PuddleCore

// Mutable fixture state is protected by condition, including test-side reads.
private final class BlockingWorkspaceDisk: SnapshotPersistence, @unchecked Sendable {
    let entered = XCTestExpectation(description: "Background write started")
    private let condition = NSCondition()
    private var blocked = true
    private var snapshots: [AppSnapshot] = []
    private var onMain = false
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func load() -> AppSnapshot { condition.withLock { onMain = onMain || Thread.isMainThread; return AppSnapshot() } }
    func save(_ snapshot: AppSnapshot) throws {
        condition.lock(); defer { condition.unlock() }
        onMain = onMain || Thread.isMainThread
        if snapshots.isEmpty { entered.fulfill() }
        while blocked { condition.wait() }
        if fail { throw PuddleError("Injected full disk") }
        snapshots.append(snapshot)
    }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
    var writes: [AppSnapshot] { condition.withLock { snapshots } }
    var usedMainThread: Bool { condition.withLock { onMain } }
}
private final class WriterSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) { lock.withLock { values[key] = data } }
    func delete(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}
final class WorkspaceWriterTests: XCTestCase {
    private static func waitForPending(_ count: Int, writer: WorkspaceWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await writer.pendingRequestCount < count {
            guard ContinuousClock.now < deadline else { XCTFail("Writes did not enter the pending batch"); throw PuddleError("Timed out waiting for writes") }
            await Task.yield()
        }
    }
    @MainActor func testWritesCoalesceAndLoadingAndSavingStayOffMainThread() async throws {
        let disk = BlockingWorkspaceDisk(), writer = WorkspaceWriter(BlockingWorkspaceDisk())
        // Separate loader needs no write gate and exercises the main-actor caller.
        _ = try await writer.load()
        let subject = WorkspaceWriter(disk)
        _ = try await subject.load()
        let first = Task { try await subject.save(AppSnapshot(), revision: 1) }
        await fulfillment(of: [disk.entered], timeout: 5)
        let edits = (2...21).map { revision in
            var snapshot = AppSnapshot(); snapshot.assistantInstructions = "Edit \(revision)"
            return Task { try await subject.save(snapshot, revision: UInt64(revision)) }
        }
        do { try await Self.waitForPending(20, writer: subject) }
        catch { disk.release(); throw error }
        disk.release()
        _ = try await first.value
        for edit in edits { _ = try await edit.value }
        XCTAssertEqual(disk.writes.count, 2)
        XCTAssertEqual(disk.writes.last?.assistantInstructions, "Edit 21")
        XCTAssertFalse(disk.usedMainThread)
    }
    func testFailedWriteRejectsPendingBatchWithoutPublishingIt() async throws {
        let disk = BlockingWorkspaceDisk(fail: true), writer = WorkspaceWriter(disk)
        let epoch: UInt64 = 1
        let first = Task { try await writer.save(AppSnapshot(), revision: 1, epoch: epoch) }
        await fulfillment(of: [disk.entered], timeout: 5)
        let pending = Task { try await writer.save(AppSnapshot(), revision: 2, epoch: epoch) }
        do { try await Self.waitForPending(1, writer: writer) }
        catch { disk.release(); throw error }
        disk.release()
        for work in [first, pending] {
            do { _ = try await work.value; XCTFail("Save must report the injected failure") }
            catch { XCTAssertTrue(error is WorkspaceWriteFailure) }
        }
        XCTAssertTrue(disk.writes.isEmpty)
        do { _ = try await writer.save(AppSnapshot(), revision: 3, epoch: epoch); XCTFail("Late arrival revived a failed batch") }
        catch { XCTAssertTrue(error is WorkspaceWriteFailure) }
    }
    func testCheckpointOnlyWritesEncryptedRecoveryAndDismissalSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-writer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = WriterSecrets(), disk = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        let writer = WorkspaceWriter(disk)
        var snapshot = AppSnapshot(); let note = MeetingNote(title: "Synthetic meeting")
        snapshot.meetings = [note]
        _ = try await writer.save(snapshot, revision: 1)
        let primary = directory.appendingPathComponent("workspace.vault")
        let original = try Data(contentsOf: primary)
        let recovery = MeetingCaptureRecovery(noteID: note.id, text: "Synthetic recovery phrase")
        try await writer.checkpoint([recovery], revision: 2)
        let stale = MeetingCaptureRecovery(noteID: note.id, text: "Stale phrase", updatedAt: .distantPast)
        let acknowledged = try await writer.checkpoint([stale], revision: 1)
        XCTAssertEqual(acknowledged.values.first?.text, recovery.text)
        XCTAssertEqual(try Data(contentsOf: primary), original)
        let sealed = try Data(contentsOf: directory.appendingPathComponent("meeting-recovery.vault"))
        XCTAssertNil(sealed.range(of: Data(recovery.text.utf8)))
        let restarted = WorkspaceWriter(EncryptedSnapshotStore(directory: directory, secrets: secrets))
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded.snapshot.meetingCaptureRecoveries.first?.text, recovery.text)
        snapshot.meetingRecoveryDismissals[note.id] = Date()
        _ = try await writer.save(snapshot, revision: 2)
        let dismissed = try await restarted.load()
        XCTAssertTrue(dismissed.snapshot.meetingCaptureRecoveries.isEmpty)
    }
    func testManyFailedEpochsUseOneWatermarkAndRejectOldArrivalsAfterSuccess() async throws {
        let disk = EpochDisk(), writer = WorkspaceWriter(disk)
        for epoch in UInt64(1)...128 {
            do { _ = try await writer.save(AppSnapshot(), revision: epoch, epoch: epoch); XCTFail("Injected failure must throw") }
            catch { XCTAssertTrue(error is WorkspaceWriteFailure) }
        }
        let rejected = await writer.rejectedThroughEpoch
        XCTAssertEqual(rejected, 128)
        disk.allowWrites()
        _ = try await writer.save(AppSnapshot(), revision: 129, epoch: 129)
        for epoch in [UInt64(1), 64, 128] {
            do { _ = try await writer.save(AppSnapshot(), revision: 130, epoch: epoch); XCTFail("Old failed epoch accepted") }
            catch { XCTAssertTrue(error is WorkspaceWriteFailure) }
        }
        _ = try await writer.save(AppSnapshot(), revision: 131, epoch: 129)
        XCTAssertEqual(disk.writeCount, 2)
    }
    @MainActor func testUnchangedCheckpointSkipsDiskAndCleanupRejectsOlderTextOffMainThread() async throws {
        let disk = RecoveryWriteDisk(), writer = WorkspaceWriter(disk)
        let values = [MeetingCaptureRecovery(noteID: UUID(), text: "Synthetic capture")]
        try await writer.checkpoint(values, revision: 1)
        try await writer.checkpoint(values, revision: 2)
        XCTAssertEqual(disk.writes.count, 1)
        try await writer.checkpoint([], revision: 4)
        let stale = try await writer.checkpoint(values, revision: 3)
        XCTAssertTrue(stale.values.isEmpty)
        XCTAssertEqual(disk.writes, [values, []])
        XCTAssertFalse(disk.usedMainThread)
    }
    func testUnreadableRecoveryDoesNotBlockWorkspaceAndIsPreservedBeforeNewCheckpoint() async throws {
        for wrongKey in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-recovery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let secrets = WriterSecrets(), disk = EncryptedSnapshotStore(directory: directory, secrets: secrets)
            var snapshot = AppSnapshot(); let note = MeetingNote(title: "Durable meeting")
            snapshot.meetings = [note]; snapshot.assistantInstructions = "Intact workspace"
            try disk.save(snapshot)
            let recovery = directory.appendingPathComponent("meeting-recovery.vault")
            let damaged: Data
            if wrongKey {
                let other = directory.appendingPathComponent("other")
                let otherDisk = EncryptedSnapshotStore(directory: other, secrets: WriterSecrets())
                try otherDisk.saveMeetingRecoveries([.init(noteID: note.id, text: "Wrong key")])
                damaged = try Data(contentsOf: other.appendingPathComponent("meeting-recovery.vault"))
            } else { damaged = Data("PUDDLEVAULT1\ntruncated".utf8) }
            try damaged.write(to: recovery)
            let writer = WorkspaceWriter(disk), loaded = try await writer.load()
            XCTAssertEqual(loaded.snapshot.assistantInstructions, "Intact workspace")
            XCTAssertEqual(loaded.snapshot.meetings.first?.id, note.id)
            XCTAssertTrue(loaded.notice?.contains("file was preserved") == true)
            let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("meeting-recovery-unreadable-") }
            XCTAssertEqual(preserved.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), damaged)
            try await writer.checkpoint([.init(noteID: note.id, text: "New capture")])
            XCTAssertEqual(try disk.loadMeetingRecoveries().first?.text, "New capture")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), damaged)
        }
    }
    func testReloadInvalidatesCheckpointWriteElision() async throws {
        let disk = RecoveryWriteDisk(), writer = WorkspaceWriter(disk)
        let values = [MeetingCaptureRecovery(noteID: UUID(), text: "Retry after reloading an external generation")]
        try await writer.checkpoint(values, revision: 1)
        _ = try await writer.load()
        try await writer.checkpoint(values, revision: 2)
        XCTAssertEqual(disk.writes, [values, values])
    }
    func testRecoveryOwnershipConflictNeverQuarantinesValidText() async throws {
        let writer = WorkspaceWriter(ConflictingRecoveryDisk())
        do { _ = try await writer.load(); XCTFail("A conflicting recovery must require reload") }
        catch { XCTAssertTrue(error is WorkspaceConflict) }
    }
}

private struct ConflictingRecoveryDisk: SnapshotPersistence {
    func load() -> AppSnapshot { AppSnapshot() }
    func save(_ snapshot: AppSnapshot) {}
    func loadMeetingRecoveries() throws -> [MeetingCaptureRecovery] { throw WorkspaceConflict.busy }
    func preserveUnreadableMeetingRecoveries() { XCTFail("Ownership conflict is not corrupt recovery data") }
}

// All mutable state is protected by lock, including test-side access.
private final class EpochDisk: SnapshotPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    private var writes = 0
    func load() -> AppSnapshot { AppSnapshot() }
    func save(_ snapshot: AppSnapshot) throws {
        try lock.withLock { if failing { throw PuddleError("Injected save failure") }; writes += 1 }
    }
    func allowWrites() { lock.withLock { failing = false } }
    var writeCount: Int { lock.withLock { writes } }
}

// Checkpoint calls and fixture reads share lock.
private final class RecoveryWriteDisk: SnapshotPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [[MeetingCaptureRecovery]] = []
    private var onMain = false
    func load() -> AppSnapshot { AppSnapshot() }
    func save(_ snapshot: AppSnapshot) {}
    func saveMeetingRecoveries(_ values: [MeetingCaptureRecovery]) {
        lock.withLock { saved.append(values); onMain = onMain || Thread.isMainThread }
    }
    var writes: [[MeetingCaptureRecovery]] { lock.withLock { saved } }
    var usedMainThread: Bool { lock.withLock { onMain } }
}
