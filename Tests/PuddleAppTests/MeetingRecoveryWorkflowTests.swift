import Foundation
import XCTest
import PuddleCore
@testable import Puddle

// Mutable credentials are synthetic and protected by lock.
private final class RecoverySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) { lock.withLock { values[key] = data } }
    func delete(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}
private struct RecoveryOfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw CancellationError() }
}
@MainActor private final class RecoveryReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}

@MainActor final class MeetingRecoveryWorkflowTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-recovery-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCorruptSidecarShowsNoticeAndKeepsStorageAvailable() async throws {
        let directory = try directory(), secrets = RecoverySecrets()
        let disk = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        var snapshot = AppSnapshot(); snapshot.meetings = [MeetingNote(title: "Intact meeting")]
        try disk.save(snapshot)
        try Data("truncated".utf8).write(to: directory.appendingPathComponent("meeting-recovery.vault"))
        let store = PuddleStore(directory: directory, cache: disk, secrets: secrets, transport: RecoveryOfflineTransport(), reminderScheduler: RecoveryReminders())
        await store.start()
        XCTAssertTrue(store.storageAvailable)
        XCTAssertEqual(store.state.meetings.first?.title, "Intact meeting")
        XCTAssertTrue(store.errorMessage?.contains("file was preserved") == true)
        await store.suspendConnectionWork()
    }
    func testDiscardAndDeleteRemoveSidecarTextAndDeletedNoteDismissals() async throws {
        let directory = try directory(), secrets = RecoverySecrets()
        let disk = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        let store = PuddleStore(directory: directory, cache: disk, secrets: secrets)
        store.storageAvailable = true
        let firstResult = await store.createMeetingNote(), secondResult = await store.createMeetingNote()
        let first = try XCTUnwrap(firstResult), second = try XCTUnwrap(secondResult)
        await store.checkpointMeetingCapture(first, text: "Discard this text")
        await store.checkpointMeetingCapture(second, text: "Retain other recovery")
        await store.discardMeetingCapture(first)
        XCTAssertEqual(try disk.loadMeetingRecoveries().map(\.text), ["Retain other recovery"])
        XCTAssertEqual(store.state.meetingRecoveryDismissals.count, 1)
        await store.deleteMeetingNote(first)
        XCTAssertTrue(store.state.meetingRecoveryDismissals.isEmpty)
        await store.deleteMeetingNote(second)
        XCTAssertTrue(try disk.loadMeetingRecoveries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovery.vault").path))
        let restarted = try await WorkspaceWriter(EncryptedSnapshotStore(directory: directory, secrets: secrets)).load()
        XCTAssertTrue(restarted.snapshot.meetingCaptureRecoveries.isEmpty)
        XCTAssertTrue(restarted.snapshot.meetingRecoveryDismissals.isEmpty)
    }
    func testApplyingRecoveryRemovesSidecarAndUnchangedCheckpointsDoNotRewriteIt() async throws {
        let directory = try directory(), secrets = RecoverySecrets()
        let disk = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        let store = PuddleStore(directory: directory, cache: disk, secrets: secrets)
        store.storageAvailable = true
        let result = await store.createMeetingNote(), id = try XCTUnwrap(result)
        await store.checkpointMeetingCapture(id, text: "Apply these words")
        let file = directory.appendingPathComponent("meeting-recovery.vault"), original = try Data(contentsOf: file)
        for _ in 0..<10 { await store.checkpointMeetingCapture(id, text: "Apply these words") }
        XCTAssertEqual(try Data(contentsOf: file), original, "Unchanged capture must not re-encrypt or rewrite the file")
        store.reviewMeetingCapture(id)
        XCTAssertTrue(store.useImportedTranscript(append: true))
        let saved = await store.saveMeetingNote(id)
        XCTAssertTrue(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try disk.load().meetings.first?.transcript, "Apply these words")
    }
}
