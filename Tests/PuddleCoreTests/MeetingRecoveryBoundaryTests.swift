import Foundation
import XCTest
@testable import PuddleCore

// Sendable invariant: synthetic credential state is protected by lock.
private final class RecoveryBoundarySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) { lock.withLock { values[key] = data } }
    func delete(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class MeetingRecoveryBoundaryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-recovery-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testRecoveryPathsRejectDirectoriesAndSymlinksBeforeReadDeleteMoveOrWrite() throws {
        for symlink in [false, true] {
            let root = try directory(), disk = EncryptedSnapshotStore(directory: root, secrets: RecoveryBoundarySecrets())
            let path = root.appendingPathComponent("meeting-recovery.vault"), target = root.appendingPathComponent("keep")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("Keep private fixture".utf8).write(to: target.appendingPathComponent("child"))
            if symlink { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
            else { try FileManager.default.copyItem(at: target, to: path) }
            XCTAssertThrowsError(try disk.loadMeetingRecoveries())
            XCTAssertThrowsError(try disk.saveMeetingRecoveries([]))
            XCTAssertThrowsError(try disk.saveMeetingRecoveries([.init(noteID: UUID(), text: "New")]))
            XCTAssertThrowsError(try disk.preserveUnreadableMeetingRecoveries())
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("child")), Data("Keep private fixture".utf8))
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("child")), Data("Keep private fixture".utf8))
        }
    }
    func testQuarantineKeepsNewestFiveRegularFilesAndSkipsNonregularPaths() throws {
        let root = try directory(), fm = FileManager.default
        let disk = EncryptedSnapshotStore(directory: root, secrets: RecoveryBoundarySecrets())
        for index in 0..<7 {
            let path = root.appendingPathComponent("meeting-recovery-unreadable-\(index).vault")
            try Data("Old \(index)".utf8).write(to: path)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
        }
        XCTAssertTrue(try disk.loadMeetingRecoveries().isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("meeting-recovery-unreadable-") }.count, 5,
                       "Startup prunes pre-existing quarantine files even without a new corruption")
        let folder = root.appendingPathComponent("meeting-recovery-unreadable-folder.vault")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Keep".utf8).write(to: folder.appendingPathComponent("child"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("meeting-recovery-unreadable-link.vault"), withDestinationURL: folder)
        try Data("Newest damaged bytes".utf8).write(to: root.appendingPathComponent("meeting-recovery.vault"))
        XCTAssertThrowsError(try disk.loadMeetingRecoveries())
        try disk.preserveUnreadableMeetingRecoveries()
        let regular = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter {
            let value = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return $0.lastPathComponent.hasPrefix("meeting-recovery-unreadable-") && value.isRegularFile == true && value.isSymbolicLink != true
        }
        XCTAssertEqual(regular.count, MeetingRecoveryLimits.maximumQuarantineCount)
        XCTAssertTrue(try regular.contains { try Data(contentsOf: $0) == Data("Newest damaged bytes".utf8) })
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("meeting-recovery-unreadable-0.vault").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("child").path))
    }
    func testRecoveryBudgetsRoundTripNearLimitAndNeverReplaceGoodFileOnOverflow() throws {
        let root = try directory(), disk = EncryptedSnapshotStore(directory: root, secrets: RecoveryBoundarySecrets())
        let text = String(repeating: "😀", count: TranscriptImport.maximumCharacters)
        let nearLimit = (0..<20).map { _ in MeetingCaptureRecovery(noteID: UUID(), text: text) }
        try disk.saveMeetingRecoveries(nearLimit)
        XCTAssertEqual(try disk.loadMeetingRecoveries(), nearLimit)
        let path = root.appendingPathComponent("meeting-recovery.vault"), before = try Data(contentsOf: path)
        let overflow = nearLimit + [.init(noteID: UUID(), text: text)]
        XCTAssertThrowsError(try disk.saveMeetingRecoveries(overflow))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertThrowsError(try disk.saveMeetingRecoveries((0...MeetingRecoveryLimits.maximumCount).map { _ in .init(noteID: UUID(), text: "Small") }))
        let combining = String(repeating: "\u{0301}", count: MeetingRecoveryLimits.maximumTextBytes / 2 + 1)
        XCTAssertThrowsError(try disk.saveMeetingRecoveries([.init(noteID: UUID(), text: combining)]))
        let escaped = (0..<16).map { _ in MeetingCaptureRecovery(noteID: UUID(), text: String(repeating: "\u{0001}", count: 200_000)) }
        XCTAssertThrowsError(try disk.saveMeetingRecoveries(escaped), "Encoded JSON byte budget includes escape expansion")
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    func testUnrelatedTranscriptSubstringDoesNotDismissRecovery() {
        let note = MeetingNote(title: "Synthetic")
        var snapshot = AppSnapshot(); snapshot.meetings = [note]
        snapshot.meetings[0].transcript = "Earlier unrelated OK passage"
        let recovery = MeetingCaptureRecovery(noteID: note.id, text: "OK")
        XCTAssertEqual(snapshot.mergingMeetingRecoveries([recovery]).meetingCaptureRecoveries, [recovery])
    }
}
