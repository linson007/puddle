import Foundation
import XCTest
@testable import PuddleCore

private final class VaultSecrets: SecretStore, @unchecked Sendable {
    let lock = NSLock(); var values: [String: Data] = [:]; var failWrites = false
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ value: Data, key: String) throws { try lock.withLock { if failWrites { throw PuddleError("Fixture keychain unavailable") }; values[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
final class EncryptedWorkspaceTests: XCTestCase {
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
