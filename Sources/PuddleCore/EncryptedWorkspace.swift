import CryptoKit
import Foundation
import CommonCrypto

/// Device-bound encryption for app state. The workspace key is stored separately in Keychain.
public struct EncryptedSnapshotStore: SnapshotPersistence {
    public let directory: URL
    private let secrets: any SecretStore
    private var file: URL { directory.appendingPathComponent("workspace.vault") }
    private var backup: URL { directory.appendingPathComponent("workspace.backup.vault") }
    private var transcripts: URL { directory.appendingPathComponent("transcripts", isDirectory: true) }
    private var keyName: String { "workspace-key-" + SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() }
    private let header = Data("PUDDLEVAULT1\n".utf8)
    private let pageHeader = Data("PUDDLECHAT1\n".utf8)
    private let cache = TranscriptVault.Cache()
    public init(directory: URL, secrets: any SecretStore = KeychainStore()) { self.directory = directory; self.secrets = secrets }
    private func key(create: Bool) throws -> SymmetricKey {
        if let data = try secrets.read(keyName) {
            guard data.count == 32 else { throw PuddleError("The workspace encryption key is invalid. Restore a portable backup.") }
            return SymmetricKey(data: data)
        }
        guard create else { throw PuddleError("The workspace key is missing from Keychain. Unlock your login keychain or restore a portable backup; encrypted files were preserved.") }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0) }, key: keyName); return key
    }
    private func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: header).combined else { throw PuddleError("Could not encrypt the workspace.") }
        return header + combined
    }
    private func sealPage(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: pageHeader).combined else { throw PuddleError("Could not encrypt the transcript.") }
        return pageHeader + combined
    }
    private func openPage(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: pageHeader) else { throw PuddleError("The transcript page is unreadable.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(pageHeader.count)), using: key, authenticating: pageHeader)
    }
    private func fingerprint(_ data: Data, key: SymmetricKey) -> Data {
        var hash = SHA256(); key.withUnsafeBytes { hash.update(bufferPointer: $0) }; hash.update(data: data)
        return Data(hash.finalize())
    }
    private struct Probe: Decodable { let schemaVersion: Int?; let format: String? }
    private func decode(_ data: Data, key: SymmetricKey) throws -> AppSnapshot {
        let plain = try open(data, key: key), probe = try JSONDecoder().decode(Probe.self, from: plain)
        guard (probe.schemaVersion ?? 0) <= AppSnapshot.currentSchemaVersion else { throw SnapshotVersionError() }
        if let format = probe.format {
            guard format == TranscriptVault.format else { throw SnapshotVersionError() }
            let index = try JSONDecoder().decode(TranscriptVault.Index.self, from: plain)
            return try TranscriptVault.restore(index, directory: transcripts, cache: cache, open: { try openPage($0, key: key) })
        }
        // Read the original single-file encrypted format without losing content.
        cache.transcripts = [:]; cache.committedNames = []; cache.needsSweep = true
        return try JSONDecoder().decode(AppSnapshot.self, from: plain)
    }
    private func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: header), data.count <= 128 * 1024 * 1024 else { throw PuddleError("The encrypted workspace is unreadable or too large.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(header.count)), using: key, authenticating: header)
    }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load() throws -> AppSnapshot { try loadResult().snapshot }
    public func loadResult() throws -> SnapshotLoadResult {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.recoveredPages = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: backup.path) else {
            let legacy = SnapshotStore(directory: directory)
            let result = try legacy.loadResult()
            if fm.fileExists(atPath: directory.appendingPathComponent("state.json").path) {
                try save(result.snapshot)
                try protectLegacyFiles()
                return SnapshotLoadResult(snapshot: result.snapshot, notice: [result.notice, "Your workspace was migrated to encrypted storage. Its key stays in Keychain."].compactMap { $0 }.joined(separator: " "))
            }
            return result
        }
        let key = try key(create: false)
        let result: SnapshotLoadResult
        do {
            let data = try Data(contentsOf: file)
            let snapshot = try decode(data, key: key)
            cache.primaryDigest = fingerprint(data, key: key)
            result = SnapshotLoadResult(snapshot: snapshot, notice: cache.recoveredPages ? "Recovered damaged transcript pages from encrypted recovery copies. All messages were retained; damaged files were preserved." : nil)
        } catch let error as SnapshotVersionError { throw error }
        catch {
            guard let data = try? Data(contentsOf: backup), let snapshot = try? decode(data, key: key) else {
                throw PuddleError("Puddle could not decrypt its workspace or recovery copy. Unlock Keychain or restore a portable backup. All files were preserved.")
            }
            if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: directory.appendingPathComponent("workspace-unreadable-\(UUID()).vault")) }
            try write(data, to: file)
            cache.primaryDigest = fingerprint(data, key: key)
            result = SnapshotLoadResult(snapshot: snapshot, notice: "Recovered the previous encrypted workspace. Recent changes may be missing.")
        }
        try protectLegacyFiles()
        return result
    }
    public func save(_ state: AppSnapshot) throws {
        try autoreleasepool { try saveContents(state) }
    }
    private func saveContents(_ state: AppSnapshot) throws {
        cache.lock.lock(); defer { cache.lock.unlock() }
        let exists = FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: backup.path)
        let key = try key(create: !exists)
        var previous: Data?
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if cache.primaryDigest != fingerprint(data, key: key) { _ = try decode(data, key: key) }
            previous = data
        } else if FileManager.default.fileExists(atPath: backup.path) {
            let data = try Data(contentsOf: backup)
            _ = try decode(data, key: key); previous = data
        }
        let oldNames = cache.committedNames
        let prepared = try TranscriptVault.prepare(state, directory: transcripts, cache: cache,
            seal: { try sealPage($0, key: key) }, open: { try openPage($0, key: key) })
        do {
            let encrypted = try seal(prepared.data, key: key)
            if let previous { try write(previous, to: backup) }
            try write(encrypted, to: file)
            cache.primaryDigest = fingerprint(encrypted, key: key)
            cache.transcripts = prepared.transcripts
            cache.committedNames = Set(prepared.index.pages.map(\.file))
        } catch {
            for page in prepared.created { try? FileManager.default.removeItem(at: page); cache.fingerprints.removeValue(forKey: TranscriptVault.cacheKey(page)) }
            throw error
        }
        let names = Set(prepared.index.pages.map(\.file))
        cache.garbageCandidates.formUnion(oldNames.subtracting(names))
        if cache.needsSweep || !cache.garbageCandidates.isEmpty {
            let roots = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if !roots.contains(where: { $0.hasPrefix("workspace-unreadable-") }) {
                let keep = names.union(oldNames), recovery = transcripts.appendingPathComponent("recovery", isDirectory: true)
                if cache.needsSweep {
                    TranscriptVault.collect(in: transcripts, keeping: keep, cache: cache)
                    TranscriptVault.collect(in: recovery, keeping: keep, cache: cache)
                    cache.needsSweep = false
                } else {
                    TranscriptVault.collectKnown(cache.garbageCandidates, in: transcripts, keeping: keep, cache: cache)
                    TranscriptVault.collectKnown(cache.garbageCandidates, in: recovery, keeping: keep, cache: cache)
                }
                cache.garbageCandidates.formIntersection(keep.subtracting(names))
            }
        }
    }
    private func protectLegacyFiles() throws {
        let fm = FileManager.default, key = try key(create: false)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for legacy in files where legacy.lastPathComponent.hasPrefix("state") && legacy.pathExtension == "json" {
            let info = try legacy.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: legacy), destination = directory.appendingPathComponent("legacy-" + legacy.lastPathComponent + ".vault")
            let encrypted = try seal(data, key: key); try write(encrypted, to: destination)
            guard try open(Data(contentsOf: destination), key: key) == data else { throw PuddleError("Legacy encryption verification failed. Original files were preserved.") }
            try fm.removeItem(at: legacy)
        }
    }
}

public enum ProtectedWorkspaceBackup {
    private struct Envelope: Codable { let format: String; let version: Int; let salt: Data; let rounds: Int; let sealed: Data }
    private static let format = "puddle-encrypted-backup"
    private static func key(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        guard salt.count == 16, (100_000...1_000_000).contains(rounds), password.utf8.count <= 1024 else { throw PuddleError("Unsupported encrypted backup parameters.") }
        let password = Array(password.utf8); var derived = [UInt8](repeating: 0, count: 32)
        let result = salt.withUnsafeBytes { salt in
            password.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, derived.count)
            }
        }
        guard result == kCCSuccess else { throw PuddleError("Could not derive the backup key.") }
        return SymmetricKey(data: derived)
    }
    public static func encode(_ snapshot: AppSnapshot, password: String) throws -> Data {
        guard password.count >= 12 else { throw PuddleError("Choose a backup passphrase with at least 12 characters. It is needed to restore this file.") }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, rounds = 600_000
        let data = try WorkspaceBackup.encode(snapshot), key = try key(password: password, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(format.utf8)).combined!
        return try JSONEncoder().encode(Envelope(format: format, version: 1, salt: salt, rounds: rounds, sealed: sealed))
    }
    public static func inspect(_ data: Data, password: String) throws -> WorkspaceBackupPreview {
        guard data.count <= WorkspaceBackup.maximumBytes * 2 else { throw PuddleError("Choose a backup under 128 MB.") }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format else { return try WorkspaceBackup.inspect(data) }
        guard envelope.version == 1 else { throw PuddleError("Unsupported encrypted backup version.") }
        let key = try key(password: password, salt: envelope.salt, rounds: envelope.rounds)
        let decoded: Data
        do { decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: Data(format.utf8)) }
        catch { throw PuddleError("The backup passphrase is incorrect or the encrypted file was changed.") }
        return try WorkspaceBackup.inspect(decoded)
    }
}
