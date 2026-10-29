import Foundation
import XCTest
@testable import PuddleCore

final class PersistenceTests: XCTestCase {
    func testArchiveReopenAndReceiptsSurviveRestart() throws {
        var state = AppSnapshot()
        let user = ChatLine(role: "user", content: "Remember this conversation")
        state.chat = [user, ChatLine(role: "assistant", content: "Saved discussion")]
        state.recordReceipt(ToolReceipt(id: "call", tool: "list_tasks", detail: "Read tasks"), userID: user.id)
        state.startNewConversation()
        let id = state.conversations[0].id
        state.chat = [ChatLine(role: "user", content: "Another discussion")]
        state.openConversation(id)
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.chat.first?.receipts?.first?.id, "call")
        XCTAssertEqual(restored.conversations.count, 1)
        XCTAssertEqual(restored.conversations[0].lines.first?.content, "Another discussion")
    }
    func testPartialLegacySettingsMigrateAndLearningTogglePersists() throws {
        let old = Data(#"{"settings":{"pollSeconds":1},"memories":[]}"#.utf8)
        var state = try JSONDecoder().decode(AppSnapshot.self, from: old)
        XCTAssertEqual(state.schemaVersion, AppSnapshot.currentSchemaVersion)
        XCTAssertEqual(state.settings.pollSeconds, 30)
        XCTAssertTrue(state.settings.automaticallyLearn)
        state.settings.automaticallyLearn = false
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(restored.settings.automaticallyLearn)
    }

    func testCorruptPrimaryRecoversBackupAndPreservesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        var original = AppSnapshot(); original.remember(title: "Name", content: "Mira")
        try store.save(original)
        var next = original; next.tasks.append(AssistantTask(title: "Review"))
        try store.save(next)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: dir.appendingPathComponent("state.json"))
        let recovered = try store.loadResult()
        XCTAssertEqual(recovered.snapshot.memories.first?.content, "Mira")
        XCTAssertNotNil(recovered.notice)
        let preserved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("state-unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved)), corrupt)
        XCTAssertNoThrow(try store.save(original))
    }

    func testUnreadableStateCannotBeReplacedByStartupDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("state.json"), corrupt = Data("{invalid".utf8)
        try corrupt.write(to: file)
        let store = SnapshotStore(directory: dir)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AppSnapshot()))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFutureVersionNeverFallsBackToOlderBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        try store.save(AppSnapshot()); try store.save(AppSnapshot())
        let file = dir.appendingPathComponent("state.json")
        let future = Data(#"{"schemaVersion":999}"#.utf8)
        try future.write(to: file)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is SnapshotVersionError) }
        XCTAssertThrowsError(try store.save(AppSnapshot()))
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
}
