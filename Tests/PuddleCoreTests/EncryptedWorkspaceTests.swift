import Foundation
import CryptoKit
import XCTest
@testable import PuddleCore

private final class VaultSecrets: SecretStore, @unchecked Sendable {
    let lock = NSLock(); var values: [String: Data] = [:]; var failWrites = false
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ value: Data, key: String) throws { try lock.withLock { if failWrites { throw PuddleError("Fixture keychain unavailable") }; values[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
final class EncryptedWorkspaceTests: XCTestCase {
    func testIndependentStoresCannotOverwriteOrDeleteNewerMeetingRecovery() throws {
        let root = try directory(), secrets = VaultSecrets()
        let first = EncryptedSnapshotStore(directory: root, secrets: secrets), second = EncryptedSnapshotStore(directory: root, secrets: secrets)
        XCTAssertTrue(try first.loadMeetingRecoveries().isEmpty); XCTAssertTrue(try second.loadMeetingRecoveries().isEmpty)
        let original = [MeetingCaptureRecovery(noteID: UUID(), text: "New recovery from first store")]
        try first.saveMeetingRecoveries(original)
        XCTAssertThrowsError(try second.saveMeetingRecoveries([]))
        XCTAssertThrowsError(try second.saveMeetingRecoveries([.init(noteID: UUID(), text: "Stale replacement")]))
        XCTAssertEqual(try second.loadMeetingRecoveries(), original)
        try second.saveMeetingRecoveries([])
        XCTAssertThrowsError(try first.saveMeetingRecoveries(original))
        XCTAssertTrue(try first.loadMeetingRecoveries().isEmpty)
        try first.saveMeetingRecoveries(original)
    }
    func testUnreadableRecoveryCannotQuarantineAChangedGeneration() throws {
        let root = try directory(), secrets = VaultSecrets(), first = EncryptedSnapshotStore(directory: root, secrets: secrets)
        try first.save(AppSnapshot())
        let recovery = root.appendingPathComponent("meeting-recovery.vault")
        try Data("damaged".utf8).write(to: recovery)
        XCTAssertThrowsError(try first.loadMeetingRecoveries())
        let second = EncryptedSnapshotStore(directory: root, secrets: secrets)
        try second.preserveUnreadableMeetingRecoveries()
        let current = [MeetingCaptureRecovery(noteID: UUID(), text: "Recovered by another process")]
        try second.saveMeetingRecoveries(current)
        XCTAssertThrowsError(try first.preserveUnreadableMeetingRecoveries())
        XCTAssertEqual(try second.loadMeetingRecoveries(), current)
        XCTAssertEqual(try first.loadMeetingRecoveries(), current)
        try first.saveMeetingRecoveries(current)
        XCTAssertEqual(try second.loadMeetingRecoveries(), current)
    }
    func testFirstMigrationRewriteRetainsVerifiedOriginalAndItsPages() throws {
        let root = try directory(), secrets = VaultSecrets(), disk = EncryptedSnapshotStore(directory: root, secrets: secrets)
        var initial = AppSnapshot(); initial.chat = [ChatLine(role: "user", content: "Original schema fixture")]
        try disk.save(initial)
        let file = root.appendingPathComponent("workspace.vault"), header = Data("PUDDLEVAULT1\n".utf8)
        let key = SymmetricKey(data: try XCTUnwrap(secrets.values.values.first))
        let current = try Data(contentsOf: file)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: current.dropFirst(header.count)), using: key, authenticating: header)
        var index = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
        index["schemaVersion"] = 0
        var snapshot = index["snapshot"] as! [String: Any]; snapshot["schemaVersion"] = 0; index["snapshot"] = snapshot
        let migratedInput = header + (try AES.GCM.seal(JSONSerialization.data(withJSONObject: index), using: key, authenticating: header).combined!)
        try migratedInput.write(to: file)
        var restored = try disk.load(); XCTAssertEqual(restored.decodedSchemaVersion, 0)
        for _ in 0..<3 { restored.chat.append(ChatLine(role: "assistant", content: "New schema")); try disk.save(restored) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace-premigration-schema-0.vault")), migratedInput)
        let originalPages = ((index["active"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []
        for page in originalPages { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcripts/" + (page["file"] as! String)).path)) }
    }
    func testIndependentStoresRejectStaleAndUnloadedSnapshots() throws {
        let folder = try directory(), secrets = VaultSecrets()
        let first = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        let second = EncryptedSnapshotStore(directory: folder, secrets: secrets)
        _ = try first.load(); _ = try second.load()
        var initial = AppSnapshot(); initial.chat = [ChatLine(role: "user", content: "First owner")]
        try first.save(initial)
        XCTAssertThrowsError(try second.save(AppSnapshot()))
        XCTAssertThrowsError(try EncryptedSnapshotStore(directory: folder, secrets: secrets).save(AppSnapshot()))
        var loaded = try second.load(); loaded.chat.append(ChatLine(role: "assistant", content: "Second owner"))
        try second.save(loaded)
        XCTAssertThrowsError(try first.save(initial))
        XCTAssertEqual(try first.load().chat.count, 2)
    }
    func testAdvisoryLockBlocksAnotherProcessBeforeWorkspaceAccess() throws {
        let folder = try directory(), child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX); print('ready', flush=True); sys.stdin.read(1)", folder.appendingPathComponent(".workspace.lock").path]
        child.standardOutput = output; child.standardInput = input
        try child.run()
        defer { try? input.fileHandleForWriting.close(); child.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        XCTAssertThrowsError(try EncryptedSnapshotStore(directory: folder, secrets: VaultSecrets()).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace.vault").path))
    }
    func testInterruptedAtomicPublicationKeepsAnEntireGeneration() throws {
        let file = try directory().appendingPathComponent("atomic-fixture")
        try DurableFile.write(Data("old".utf8), to: file)
        XCTAssertThrowsError(try DurableFile.write(Data("new".utf8), to: file) { stage in
            if stage == .beforeRename { throw PuddleError("Injected interruption") }
        })
        XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
        XCTAssertThrowsError(try DurableFile.write(Data("new".utf8), to: file) { stage in
            if stage == .afterRename { throw PuddleError("Injected directory flush failure") }
        })
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-vault-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testVaultRoundTripDoesNotStorePlaintextAndUsesFreshNonces() throws {
        let directory = try directory(), secrets = VaultSecrets(), store = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        var state = AppSnapshot(); state.chat = [ChatLine(role: "user", content: "Confidential fixture message")]
        try store.save(state)
        let first = try Data(contentsOf: directory.appendingPathComponent("workspace.vault"))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("Confidential fixture"))
        XCTAssertEqual(try store.load().chat, state.chat)
        try store.save(state)
        XCTAssertNotEqual(first, try Data(contentsOf: directory.appendingPathComponent("workspace.vault")))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("workspace.vault").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testLegacyMigrationEncryptsAllCopiesBeforeRemovingPlaintext() throws {
        let directory = try directory(), secrets = VaultSecrets(), legacy = SnapshotStore(directory: directory)
        var state = AppSnapshot(); state.remember(title: "Fixture", content: "Private fixture")
        try legacy.save(state); try legacy.save(state)
        let store = EncryptedSnapshotStore(directory: directory, secrets: secrets), result = try store.loadResult()
        XCTAssertEqual(result.snapshot.memories.count, 1); XCTAssertNotNil(result.notice)
        let paths = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(paths.contains("state.json")); XCTAssertFalse(paths.contains("state.backup.json"))
        XCTAssertTrue(paths.contains("legacy-state.json.vault")); XCTAssertTrue(paths.contains("legacy-state.backup.json.vault"))
        XCTAssertEqual(try store.load().memories.first?.content, "Private fixture")
    }
    func testFailedKeyStoragePreservesLegacyState() throws {
        let directory = try directory(), secrets = VaultSecrets(); secrets.failWrites = true
        var state = AppSnapshot(); state.chat = [ChatLine(role: "user", content: "Keep me")]
        try SnapshotStore(directory: directory).save(state)
        XCTAssertThrowsError(try EncryptedSnapshotStore(directory: directory, secrets: secrets).load())
        XCTAssertEqual(try SnapshotStore(directory: directory).load().chat.first?.content, "Keep me")
    }
    func testMissingKeyNeverOverwritesEncryptedData() throws {
        let directory = try directory(), secrets = VaultSecrets(), store = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        try store.save(AppSnapshot()); let before = try Data(contentsOf: directory.appendingPathComponent("workspace.vault"))
        secrets.values = [:]
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(AppSnapshot()))
        XCTAssertEqual(before, try Data(contentsOf: directory.appendingPathComponent("workspace.vault")))
    }
    func testCorruptPrimaryRecoversPreviousCiphertextAndPreservesDamagedFile() throws {
        let directory = try directory(), store = EncryptedSnapshotStore(directory: directory, secrets: VaultSecrets())
        var state = AppSnapshot(); state.chat = [ChatLine(role: "user", content: "Before")]
        try store.save(state); state.chat = []; try store.save(state)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("workspace.vault"))
        let result = try store.loadResult()
        XCTAssertEqual(result.snapshot.chat.first?.content, "Before"); XCTAssertNotNil(result.notice)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix("workspace-unreadable-") }))
    }
    func testPortableBackupRequiresCorrectPassphraseAndRejectsTampering() throws {
        var state = AppSnapshot(); state.chat = [ChatLine(role: "user", content: "Portable fixture")]
        let data = try ProtectedWorkspaceBackup.encode(state, password: "fixture passphrase 123")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Portable fixture"))
        XCTAssertEqual(try ProtectedWorkspaceBackup.inspect(data, password: "fixture passphrase 123").conversationsCount, 1)
        XCTAssertThrowsError(try ProtectedWorkspaceBackup.inspect(data, password: "incorrect"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var sealed = Data(base64Encoded: object["sealed"] as! String)!; sealed[sealed.count - 1] ^= 1
        object["sealed"] = sealed.base64EncodedString()
        XCTAssertThrowsError(try ProtectedWorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: object), password: "fixture passphrase 123"))
        XCTAssertThrowsError(try ProtectedWorkspaceBackup.encode(state, password: "short"))
    }
}
