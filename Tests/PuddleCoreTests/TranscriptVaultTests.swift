import CryptoKit
import Foundation
import XCTest
@testable import PuddleCore

private final class TranscriptSecrets: SecretStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data, key: String) throws { values[key] = data }
    func delete(_ key: String) throws { values.removeValue(forKey: key) }
}
final class TranscriptVaultTests: XCTestCase {
    private let header = Data("PUDDLEVAULT1\n".utf8)
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-vault-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func state() -> AppSnapshot {
        var result = AppSnapshot()
        result.chat = (0..<513).map { ChatLine(role: "user", content: "Synthetic message \($0)") }
        result.conversations = [Conversation(lines: [ChatLine(role: "user", content: "Archived text")])]
        result.tasks = [AssistantTask(title: "Original")]
        return result
    }
    private func files(_ folder: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("transcripts").path).filter { $0.hasSuffix(".vault") && UUID(uuidString: String($0.dropLast(6))) != nil }) }
    private func index(_ folder: URL, secrets: TranscriptSecrets) throws -> TranscriptVault.Index {
        let data = try Data(contentsOf: folder.appendingPathComponent("workspace.vault"))
        let key = SymmetricKey(data: try XCTUnwrap(secrets.values.values.first))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(header.count)), using: key, authenticating: header)
        return try JSONDecoder().decode(TranscriptVault.Index.self, from: plain)
    }
    private func replaceRoot(_ object: Any, folder: URL, secrets: TranscriptSecrets) throws {
        let key = SymmetricKey(data: try XCTUnwrap(secrets.values.values.first)), plain = try JSONSerialization.data(withJSONObject: object)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: header)
        try (header + XCTUnwrap(sealed.combined)).write(to: folder.appendingPathComponent("workspace.vault"), options: .atomic)
    }
    func testUnrelatedEditsReuseTranscriptCiphertextAndPreserveAllMessages() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        let before = try files(folder), first = try index(folder, secrets: secrets)
        state.tasks[0].title = "Edited"; state.remember(title: "Preference", content: "Concise")
        try store.save(state)
        XCTAssertEqual(try files(folder), before)
        let second = try index(folder, secrets: secrets)
        XCTAssertEqual(first.conversations, second.conversations); XCTAssertEqual(first.active, second.active)
        let restored = try EncryptedSnapshotStore(directory: folder, secrets: secrets).load()
        XCTAssertEqual(restored.chat, state.chat); XCTAssertEqual(restored.conversations, state.conversations)
        XCTAssertEqual(restored.tasks[0].title, "Edited"); XCTAssertEqual(restored.memories.count, 1)
        for file in before {
            let url = folder.appendingPathComponent("transcripts/" + file), data = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Synthetic message"))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
    }
    func testAppendingOnlyChangesTheLastPageAndOldGenerationsAreCollected() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        let first = try index(folder, secrets: secrets)
        for count in 0..<30 { state.chat.append(ChatLine(role: "assistant", content: "Reply \(count)")); try store.save(state) }
        let last = try index(folder, secrets: secrets)
        XCTAssertEqual(first.active.pages[0], last.active.pages[0])
        XCTAssertNotEqual(first.active.pages[1], last.active.pages[1])
        XCTAssertEqual(first.conversations, last.conversations)
        // One archived page, one fixed active page, current + previous tail.
        XCTAssertLessThanOrEqual(try files(folder).count, 4)
        XCTAssertEqual(try store.load().chat, state.chat)
    }
    func testSecondCommitRemovesHistoryAfterItLeavesBothRecoveryGenerations() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        let archived = try index(folder, secrets: secrets).conversations[0].pages[0].file
        state.conversations = []; try store.save(state)
        XCTAssertTrue(try files(folder).contains(archived), "The rolling recovery copy still needs this page")
        try store.save(state)
        XCTAssertFalse(try files(folder).contains(archived), "Neither committed generation references the deleted history")
        XCTAssertTrue(try store.load().conversations.isEmpty)
    }
    func testCorruptTailRepairsFromReplicaWithoutLosingLatestMessages() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        state.chat.append(ChatLine(role: "assistant", content: "Latest")); try store.save(state)
        let current = try index(folder, secrets: secrets), file = folder.appendingPathComponent("transcripts/" + current.active.pages.last!.file)
        let broken = Data("damaged transcript".utf8); try broken.write(to: file)
        let recovered = try store.loadResult()
        XCTAssertEqual(recovered.snapshot.chat, state.chat); XCTAssertNotNil(recovered.notice)
        try store.save(recovered.snapshot)
        XCTAssertNotEqual(try Data(contentsOf: file), broken)
        let damaged = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("damaged-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(damaged)), broken)
    }
    func testChangedCachedCiphertextOrKeyCannotBeSilentlyOverwritten() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        let state = state(); try store.save(state)
        let current = try index(folder, secrets: secrets), file = folder.appendingPathComponent("transcripts/" + current.active.pages[0].file)
        var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 1; try bytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        XCTAssertNoThrow(try store.save(state))
        XCTAssertEqual(try store.load().chat, state.chat)
        let root = try Data(contentsOf: folder.appendingPathComponent("workspace.vault"))
        for name in secrets.values.keys { secrets.values[name] = Data(repeating: 0, count: 32) }
        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("workspace.vault")), root)
    }
    func testLossOfBothLatestPageCopiesFallsBackToThePreviousCommittedGeneration() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        let before = state.chat
        state.chat.append(ChatLine(role: "assistant", content: "Latest")); try store.save(state)
        let latest = try index(folder, secrets: secrets).active.pages.last!.file
        try Data("broken".utf8).write(to: folder.appendingPathComponent("transcripts/" + latest))
        try Data("broken replica".utf8).write(to: folder.appendingPathComponent("transcripts/recovery/" + latest))
        let result = try store.loadResult()
        XCTAssertEqual(result.snapshot.chat, before); XCTAssertNotNil(result.notice)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("workspace-unreadable-") })
    }
    func testMissingRecoveryCopyIsRebuiltFromTheVerifiedPrimaryPage() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        let state = state(); try store.save(state)
        let first = try index(folder, secrets: secrets).active.pages[0].file
        let replica = folder.appendingPathComponent("transcripts/recovery/" + first)
        try FileManager.default.removeItem(at: replica)
        XCTAssertEqual(try store.loadResult().snapshot.chat, state.chat)
        XCTAssertEqual(try Data(contentsOf: replica), try Data(contentsOf: folder.appendingPathComponent("transcripts/" + first)))
    }
    func testFailedIndexCommitRemovesUncommittedPagesAndKeepsTheOldWorkspace() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        var state = state(); try store.save(state)
        let before = try files(folder), root = try Data(contentsOf: folder.appendingPathComponent("workspace.vault"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("workspace.backup.vault"), withIntermediateDirectories: true)
        state.chat.append(ChatLine(role: "assistant", content: "Unsaved"))
        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(try files(folder), before)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("workspace.vault")), root)
        XCTAssertEqual(try store.load().chat.count, 513)
    }
    func testSingleFileSchemaSevenMigratesAndFutureRootsNeverFallBack() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        let state = state(); try store.save(state)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]; object["schemaVersion"] = 7
        try replaceRoot(object, folder: folder, secrets: secrets)
        let loaded = try store.load(); XCTAssertEqual(loaded.chat, state.chat); XCTAssertEqual(loaded.schemaVersion, 8)
        try store.save(loaded)
        XCTAssertEqual(try index(folder, secrets: secrets).schemaVersion, 8)
        try replaceRoot(["schemaVersion": 999], folder: folder, secrets: secrets)
        let future = try Data(contentsOf: folder.appendingPathComponent("workspace.vault"))
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is SnapshotVersionError) }
        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("workspace.vault")), future)
    }
    func testTranscriptSymlinksAreRejectedWithoutReadingTheirTargets() throws {
        let folder = try folder(), secrets = TranscriptSecrets(), store = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        let state = state(); try store.save(state)
        let current = try index(folder, secrets: secrets), file = folder.appendingPathComponent("transcripts/" + current.active.pages[0].file)
        let moved = folder.appendingPathComponent("preserved-page")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(state))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
}
