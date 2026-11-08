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
        cache.migrationSourceVersion = (probe.schemaVersion ?? 0) < AppSnapshot.currentSchemaVersion ? (probe.schemaVersion ?? 0) : nil
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
    private func write(_ data: Data, to url: URL, checkpoint: (DurableFile.Stage) throws -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try DurableFile.write(data, to: url, checkpoint: checkpoint)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load() throws -> AppSnapshot { try loadResult().snapshot }
    private func withOwnership<T>(_ operation: () throws -> T) throws -> T {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if cache.fileLock != nil { return try operation() }
        cache.fileLock = try WorkspaceFileLock(directory: directory)
        defer { cache.fileLock = nil }
        return try operation()
    }
    public func loadResult() throws -> SnapshotLoadResult { try withOwnership { try loadContents() } }
    private func loadContents() throws -> SnapshotLoadResult {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.recoveredPages = false
        cache.generationObserved = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: backup.path) else {
            cache.primaryDigest = nil; cache.primaryMetadata = nil; cache.primaryKeyDigest = nil
            cache.transcripts = [:]; cache.committedNames = []; cache.migrationSourceVersion = nil
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
            cache.primaryMetadata = try TranscriptVault.fingerprint(file)
            cache.primaryKeyDigest = fingerprint(header, key: key)
            result = SnapshotLoadResult(snapshot: snapshot, notice: cache.recoveredPages ? "Recovered damaged transcript pages from encrypted recovery copies. All messages were retained; damaged files were preserved." : nil)
        } catch let error as SnapshotVersionError { throw error }
        catch {
            guard let data = try? Data(contentsOf: backup), let snapshot = try? decode(data, key: key) else {
                throw PuddleError("Puddle could not decrypt its workspace or recovery copy. Unlock Keychain or restore a portable backup. All files were preserved.")
            }
            if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: directory.appendingPathComponent("workspace-unreadable-\(UUID()).vault")) }
            try write(data, to: file)
            cache.primaryDigest = fingerprint(data, key: key)
            cache.primaryMetadata = try TranscriptVault.fingerprint(file)
            cache.primaryKeyDigest = fingerprint(header, key: key)
            result = SnapshotLoadResult(snapshot: snapshot, notice: "Recovered the previous encrypted workspace. Recent changes may be missing.")
        }
        try protectLegacyFiles()
        return result
    }
    public func save(_ state: AppSnapshot) throws {
        try withOwnership { try autoreleasepool { try saveContents(state) } }
    }
    private func saveContents(_ state: AppSnapshot) throws {
        cache.lock.lock(); defer { cache.lock.unlock() }
        let exists = FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: backup.path)
        let key = try key(create: !exists)
        if exists {
            guard cache.generationObserved else { throw PuddleError("Load the existing workspace before saving changes.") }
            let current = try Data(contentsOf: file)
            guard cache.primaryDigest == fingerprint(current, key: key) else {
                throw PuddleError("The workspace changed in another process. Reload it before saving; your stale snapshot was not written.")
            }
        } else if cache.generationObserved, cache.primaryDigest != nil {
            throw PuddleError("The saved workspace was removed. Reload before saving changes.")
        }
        let fm = FileManager.default
        var previous: URL?
        if fm.fileExists(atPath: file.path) {
            let metadata = try TranscriptVault.fingerprint(file)
            if cache.primaryMetadata != metadata || cache.primaryKeyDigest != fingerprint(header, key: key) {
                let data = try Data(contentsOf: file)
                if cache.primaryDigest != fingerprint(data, key: key) { _ = try decode(data, key: key) }
            }
            previous = file
        } else if fm.fileExists(atPath: backup.path) {
            _ = try decode(Data(contentsOf: backup), key: key)
        }
        let oldNames = cache.committedNames
        if let source = cache.migrationSourceVersion, let previous {
            let preserved = directory.appendingPathComponent("workspace-premigration-schema-\(source).vault")
            if !fm.fileExists(atPath: preserved.path) {
                let original = try Data(contentsOf: previous)
                try DurableFile.write(original, to: preserved)
                guard try Data(contentsOf: preserved) == original else { throw PuddleError("Pre-migration verification failed. The original workspace was preserved.") }
            }
        }
        let prepared = try TranscriptVault.prepare(state, directory: transcripts, cache: cache,
            seal: { try sealPage($0, key: key) }, open: { try openPage($0, key: key) })
        var indexPublished = false
        do {
            let encrypted = try seal(prepared.data, key: key)
            if let previous {
                if fm.fileExists(atPath: backup.path) { _ = try TranscriptVault.fingerprint(backup) }
                try DurableFile.write(Data(contentsOf: previous), to: backup)
            }
            try write(encrypted, to: file) { if $0 == .afterRename { indexPublished = true } }
            cache.generationObserved = true
            cache.primaryDigest = fingerprint(encrypted, key: key)
            cache.primaryMetadata = try TranscriptVault.fingerprint(file)
            cache.primaryKeyDigest = fingerprint(header, key: key)
            cache.transcripts = prepared.transcripts
            cache.committedNames = Set(prepared.index.pages.map(\.file))
        } catch {
            if !indexPublished {
                for page in prepared.created { PuddleDiagnostics.removeRecoveryFile(page); cache.fingerprints.removeValue(forKey: TranscriptVault.cacheKey(page)) }
            }
            cache.needsSweep = true
            throw error
        }
        let names = Set(prepared.index.pages.map(\.file))
        cache.garbageCandidates.formUnion(oldNames.subtracting(names))
        if cache.needsSweep || !cache.garbageCandidates.isEmpty {
            let roots = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if !roots.contains(where: { $0.hasPrefix("workspace-unreadable-") || $0.hasPrefix("workspace-premigration-") }) {
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
    public func loadMeetingRecoveries() throws -> [MeetingCaptureRecovery] { try withOwnership { return try loadMeetingRecoveryContents() } }
    private func loadMeetingRecoveryContents() throws -> [MeetingCaptureRecovery] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try pruneMeetingRecoveryQuarantine() }
            catch { PuddleDiagnostics.failure(.persistence, "Prune meeting recovery quarantine", error) }
        }
        let url = directory.appendingPathComponent("meeting-recovery.vault")
        try TranscriptVault.rejectNonregular(url)
        cache.recoveryMetadata = FileManager.default.fileExists(atPath: url.path) ? try TranscriptVault.fingerprint(url) : nil
        cache.recoveryGenerationObserved = true
        guard FileManager.default.fileExists(atPath: url.path) else { cache.unreadableMeetingRecovery = false; return [] }
        guard try TranscriptVault.fingerprint(url).bytes <= MeetingRecoveryLimits.maximumBytes + 64 else {
            throw PuddleError("The meeting recovery file exceeds its size limit. It was preserved.")
        }
        let values = try JSONDecoder().decode([MeetingCaptureRecovery].self, from: open(Data(contentsOf: url), key: key(create: false)))
        try MeetingRecoveryLimits.validate(values)
        cache.unreadableMeetingRecovery = false
        return values
    }
    public func saveMeetingRecoveries(_ values: [MeetingCaptureRecovery]) throws { try withOwnership { try saveMeetingRecoveryContents(values) } }
    private func saveMeetingRecoveryContents(_ values: [MeetingCaptureRecovery]) throws {
        cache.lock.lock(); defer { cache.lock.unlock() }
        let url = directory.appendingPathComponent("meeting-recovery.vault")
        try TranscriptVault.rejectNonregular(url)
        try MeetingRecoveryLimits.validate(values)
        // If quarantine previously failed, preserve the unreadable file before
        // allowing a checkpoint to replace it.
        if cache.unreadableMeetingRecovery { try preserveUnreadableMeetingRecoveries() }
        let current = FileManager.default.fileExists(atPath: url.path) ? try TranscriptVault.fingerprint(url) : nil
        guard (cache.recoveryGenerationObserved && cache.recoveryMetadata == current) || (!cache.recoveryGenerationObserved && current == nil) else {
            throw WorkspaceConflict.staleRecovery
        }
        if values.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url); try DurableFile.syncDirectory(directory) }
            cache.recoveryGenerationObserved = true; cache.recoveryMetadata = nil
            return
        }
        let data = try JSONEncoder().encode(values)
        guard data.count <= MeetingRecoveryLimits.maximumBytes else {
            throw PuddleError("Meeting recovery storage is full. Review existing recoveries before retrying. Previous recovery files were preserved.")
        }
        // Never create a new key over an existing workspace/recovery file.
        let exists = FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: backup.path) ||
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovery.vault").path)
        try write(seal(data, key: key(create: !exists)), to: url)
        cache.recoveryGenerationObserved = true; cache.recoveryMetadata = try TranscriptVault.fingerprint(url)
    }
    public func preserveUnreadableMeetingRecoveries() throws { try withOwnership { try preserveUnreadableMeetingRecoveryContents() } }
    private func preserveUnreadableMeetingRecoveryContents() throws {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.unreadableMeetingRecovery = true
        let url = directory.appendingPathComponent("meeting-recovery.vault")
        try TranscriptVault.rejectNonregular(url)
        if cache.recoveryGenerationObserved {
            let current = FileManager.default.fileExists(atPath: url.path) ? try TranscriptVault.fingerprint(url) : nil
            guard current == cache.recoveryMetadata else { throw WorkspaceConflict.staleRecovery }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let preserved = directory.appendingPathComponent("meeting-recovery-unreadable-\(UUID()).vault")
            try FileManager.default.moveItem(at: url, to: preserved)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: preserved.path)
        }
        cache.unreadableMeetingRecovery = false
        cache.recoveryGenerationObserved = true; cache.recoveryMetadata = nil
        try pruneMeetingRecoveryQuarantine()
    }
    private func pruneMeetingRecoveryQuarantine() throws {
        let fm = FileManager.default
        let candidates = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("meeting-recovery-unreadable-") && $0.pathExtension == "vault" }
        var regular: [(URL, Date)] = []
        for url in candidates {
            do {
                try TranscriptVault.rejectNonregular(url)
                regular.append((url, try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast))
            } catch { PuddleDiagnostics.failure(.persistence, "Inspect meeting recovery quarantine", error) }
        }
        regular.sort { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 > $1.1 }
        for (url, _) in regular.dropFirst(MeetingRecoveryLimits.maximumQuarantineCount) {
            try TranscriptVault.rejectNonregular(url)
            try fm.removeItem(at: url)
            PuddleDiagnostics.meetingRecoveryPruned()
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
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(format.utf8)).combined else {
            throw PuddleError("The encrypted backup could not be encoded.")
        }
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
