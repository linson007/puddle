import Darwin
import Foundation
import XCTest
@testable import PuddleCore

private final class FilesystemSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

/// Actual filesystem errors in a bounded disposable image; never fills the host disk.
final class FilesystemRecoveryAcceptanceTests: XCTestCase {
    private final class Volume {
        let format: String
        let sizeMiB: Int
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-filesystem-\(UUID())")
        var mount: URL { root.appendingPathComponent("volume") }
        var image: URL { root.appendingPathComponent("test.sparseimage") }
        var workspace: URL { mount.appendingPathComponent("workspace") }
        var mounted = false
        init(format: String = "HFS+") throws {
            self.format = format; sizeMiB = format == "APFS" ? 128 : 32
            guard ProcessInfo.processInfo.environment["PUDDLE_FILESYSTEM_TESTS"] == "1" else {
                throw XCTSkip("Set PUDDLE_FILESYSTEM_TESTS=1 for bounded disposable disk-full/read-only/upgrade drills")
            }
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            do {
                try run(["create", "-quiet", "-size", "\(sizeMiB)m", "-type", "SPARSE", "-fs", format, "-volname", "Puddle Acceptance", image.path])
                try attach()
            } catch { cleanup(); throw error }
        }
        deinit { cleanup() }
        private func run(_ arguments: [String]) throws {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
            process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw PuddleError("Disposable-volume command failed: \(String(decoding: data, as: UTF8.self))") }
        }
        func attach(readOnly: Bool = false) throws {
            try run(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path] + (readOnly ? ["-readonly"] : []) + [image.path])
            mounted = true
        }
        func detach() throws {
            if mounted { try run(["detach", "-quiet", mount.path]); mounted = false }
        }
        private func cleanup() {
            if mounted {
                do { try run(["detach", "-quiet", mount.path]); mounted = false }
                catch {
                    // Preserve the bounded fixture instead of traversing a mounted volume.
                    fputs("Could not detach disposable acceptance volume: \(mount.path)\n", stderr)
                    return
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        func fill() throws -> URL {
            let file = mount.appendingPathComponent("synthetic-filler")
            let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            let bytes = [UInt8](repeating: 0x5a, count: 65_536)
            var total = 0, full = false
            try bytes.withUnsafeBytes { buffer in
                while total < sizeMiB * 2 * 1024 * 1024 {
                    let count = write(descriptor, buffer.baseAddress!, buffer.count)
                    if count < 0 {
                        guard errno == ENOSPC else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        full = true; break
                    }
                    guard count > 0 else { throw PuddleError("The disposable volume stopped accepting data without ENOSPC") }
                    total += count
                }
            }
            guard full else { throw PuddleError("The bounded disposable image did not report disk full") }
            print("FILESYSTEM: \(format) \(sizeMiB) MiB disposable image returned ENOSPC after \(total) bytes")
            return file
        }
    }
    private func state() -> AppSnapshot {
        var state = AppSnapshot()
        state.chat = [ChatLine(role: "user", content: "Synthetic retained transcript")]
        state.tasks = [AssistantTask(title: "Retain this commitment")]
        state.remember(title: "Style", content: "Practical replies")
        return state
    }

    func testActualFullVolumeRejectsSaveWithoutChangingCommittedStateAndCanRecover() throws {
        try fullVolume(format: "HFS+")
    }
    func testAPFSFullVolumePreservesCommittedWorkspaceAndRecovers() throws {
        try fullVolume(format: "APFS")
    }
    private func fullVolume(format: String) throws {
        let volume = try Volume(format: format), secrets = FilesystemSecrets()
        let store = EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets), original = state()
        try store.save(original)
        let root = volume.workspace.appendingPathComponent("workspace.vault"), committed = try Data(contentsOf: root)
        let filler = try volume.fill()
        var changed = original
        changed.chat.append(ChatLine(role: "assistant", content: String(repeating: "Synthetic new content. ", count: 500)))
        changed.tasks[0].title = "Unsaved change"
        XCTAssertThrowsError(try store.save(changed))
        XCTAssertEqual(try Data(contentsOf: root), committed)
        try FileManager.default.removeItem(at: filler)
        let reopened = EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets)
        let recovered = try reopened.load()
        XCTAssertEqual(recovered.chat, original.chat); XCTAssertEqual(recovered.tasks, original.tasks)
        try reopened.save(changed)
        XCTAssertEqual(try reopened.load().tasks[0].title, "Unsaved change")
        let backup = try ProtectedWorkspaceBackup.encode(try reopened.load(), password: "synthetic recovery passphrase")
        let preview = try ProtectedWorkspaceBackup.inspect(backup, password: "synthetic recovery passphrase")
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot())
        XCTAssertEqual(restored.0.tasks.first?.title, "Unsaved change")
        XCTAssertEqual(WorkspaceBackup.merging(preview, into: restored.0).1.tasksAdded, 0)
    }

    func testReadOnlyMountedWorkspaceRemainsReadableAndRejectsMutation() throws {
        try readOnlyVolume(format: "HFS+")
    }
    func testAPFSReadOnlyWorkspaceRemainsReadableAndRejectsMutation() throws {
        try readOnlyVolume(format: "APFS")
    }
    private func readOnlyVolume(format: String) throws {
        let volume = try Volume(format: format), secrets = FilesystemSecrets(), original = state()
        try EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets).save(original)
        let committed = try Data(contentsOf: volume.workspace.appendingPathComponent("workspace.vault"))
        try volume.detach(); try volume.attach(readOnly: true)
        let readOnly = EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets)
        XCTAssertEqual(try readOnly.load().chat, original.chat)
        var changed = original; changed.tasks[0].title = "Must not be saved"
        XCTAssertThrowsError(try readOnly.save(changed))
        XCTAssertEqual(try Data(contentsOf: volume.workspace.appendingPathComponent("workspace.vault")), committed)
        try volume.detach(); try volume.attach()
        XCTAssertEqual(try EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets).load().tasks, original.tasks)
    }

    func testAPFSLargeLegacyUpgradeAndPreUpgradeBackupRestore() throws {
        let volume = try Volume(format: "APFS"), secrets = FilesystemSecrets()
        var original = state(); original.schemaVersion = 7
        original.conversations = (0..<120).map { index in
            Conversation(lines: (0..<80).map { ChatLine(role: $0 % 2 == 0 ? "user" : "assistant",
                content: "Synthetic archived conversation \(index), message \($0): " + String(repeating: "retained text ", count: 20)) })
        }
        original.tasks += (0..<500).map { AssistantTask(title: "Synthetic commitment \($0)") }
        let legacy = SnapshotStore(directory: volume.workspace)
        try legacy.save(original); try legacy.save(original)
        let backupFile = volume.mount.appendingPathComponent("pre-upgrade.puddlebackup")
        let password = "synthetic pre-upgrade passphrase"
        try ProtectedWorkspaceBackup.encode(try legacy.load(), password: password).write(to: backupFile, options: .atomic)
        let upgraded = EncryptedSnapshotStore(directory: volume.workspace, secrets: secrets)
        let result = try upgraded.loadResult()
        XCTAssertNotNil(result.notice)
        XCTAssertEqual(result.snapshot.chat, original.chat)
        XCTAssertEqual(result.snapshot.conversations, original.conversations)
        XCTAssertEqual(result.snapshot.tasks, original.tasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.workspace.appendingPathComponent("state.json").path))
        try upgraded.save(result.snapshot)
        XCTAssertEqual(try upgraded.load().conversations, original.conversations)

        let preview = try ProtectedWorkspaceBackup.inspect(Data(contentsOf: backupFile), password: password)
        let (restored, _) = WorkspaceBackup.merging(preview, into: AppSnapshot())
        let restore = EncryptedSnapshotStore(directory: volume.mount.appendingPathComponent("restored-workspace"), secrets: secrets)
        try restore.save(restored)
        let reopened = try restore.load()
        XCTAssertEqual(reopened.tasks, original.tasks)
        XCTAssertEqual(reopened.conversations.count, original.conversations.count + 1)
        let lines = reopened.conversations.flatMap(\.lines)
        XCTAssertEqual(lines.count, original.conversations.flatMap(\.lines).count + original.chat.count)
        XCTAssertTrue(lines.contains { $0.content == original.chat[0].content })
        XCTAssertEqual(WorkspaceBackup.merging(preview, into: reopened).1.conversationsAdded, 0)
        // This tests the data recovery procedure, not a signed older app/installer.
    }
}
