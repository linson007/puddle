import CryptoKit
import Darwin
import Foundation

/// Immutable encrypted transcript pages. Only the active page is replaced while
/// chatting; unrelated edits never serialize archived message bodies.
enum TranscriptVault {
    static let format = "puddle-transcript-index-1"
    static let pageSize = 512
    static let maximumBytes = 120 * 1024 * 1024
    struct Page: Codable, Equatable, Sendable {
        let file: String
        let sha256: String
        let bytes: Int
    }
    struct Transcript: Codable, Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let pages: [Page]
    }
    struct Index: Codable, Sendable {
        let format: String
        let schemaVersion: Int
        let snapshot: AppSnapshot
        let conversations: [Transcript]
        let active: Transcript
        var pages: [Page] { conversations.flatMap(\.pages) + active.pages }
    }
    struct CachedTranscript {
        let value: Conversation
        let reference: Transcript
    }
    struct Fingerprint: Equatable {
        let inode: UInt64, bytes: Int64, seconds: Int, nanoseconds: Int
    }
    final class Cache: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var transcripts: [UUID: CachedTranscript] = [:]
        var fingerprints: [String: Fingerprint] = [:]
        var primaryDigest: Data?
        var committedNames = Set<String>()
        var garbageCandidates = Set<String>()
        var needsSweep = true
        var recoveredPages = false
    }
    struct Prepared {
        let data: Data
        let index: Index
        let transcripts: [UUID: CachedTranscript]
        let created: [URL]
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func cacheKey(_ file: URL) -> String { (file.deletingLastPathComponent().lastPathComponent == "recovery" ? "recovery/" : "") + file.lastPathComponent }
    private static func ensureDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw PuddleError("The transcript directory is not a regular folder.") }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private static func rejectNonregular(_ file: URL) throws {
        var value = stat()
        if lstat(file.path, &value) == 0, value.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) { throw PuddleError("A transcript path is not a regular file. It was not followed or replaced.") }
    }
    private static func replaceDamaged(_ file: URL, with data: Data, cache: Cache) throws {
        try rejectNonregular(file)
        if FileManager.default.fileExists(atPath: file.path) {
            let preserved = file.deletingLastPathComponent().appendingPathComponent("damaged-\(UUID())-" + file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: preserved)
        }
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        cache.fingerprints[cacheKey(file)] = try fingerprint(file)
        cache.recoveredPages = true
    }
    static func fingerprint(_ file: URL) throws -> Fingerprint {
        var value = stat()
        guard lstat(file.path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PuddleError("A saved transcript page is missing or is not a regular file. Workspace files were preserved.")
        }
        return Fingerprint(inode: value.st_ino, bytes: value.st_size, seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
    }
    private static func location(_ page: Page, directory: URL) throws -> URL {
        guard page.file.hasSuffix(".vault"), page.file.count == 42,
              UUID(uuidString: String(page.file.dropLast(6))) != nil,
              (1...maximumBytes).contains(page.bytes), page.sha256.count == 64 else {
            throw PuddleError("The workspace contains an invalid transcript reference.")
        }
        return directory.appendingPathComponent(page.file)
    }
    private static func read(_ page: Page, directory: URL, cache: Cache, open: (Data) throws -> Data) throws -> [ChatLine] {
        let file = try location(page, directory: directory), recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try ensureDirectory(recovery)
        let replica = recovery.appendingPathComponent(page.file)
        try rejectNonregular(file); try rejectNonregular(replica)
        func validated(_ url: URL) throws -> (Data, [ChatLine]) {
            let info = try fingerprint(url)
            guard info.bytes <= maximumBytes + 1024 else { throw PuddleError("A saved transcript page exceeds its size limit.") }
            let data = try Data(contentsOf: url)
            guard digest(data) == page.sha256 else { throw PuddleError("A saved transcript failed its integrity check. Workspace files were preserved.") }
            let plaintext = try open(data)
            guard plaintext.count == page.bytes else { throw PuddleError("A saved transcript has an invalid size.") }
            let lines = try JSONDecoder().decode([ChatLine].self, from: plaintext)
            guard !lines.isEmpty, lines.count <= pageSize else { throw PuddleError("A saved transcript page is invalid.") }
            cache.fingerprints[cacheKey(url)] = info
            return (data, lines)
        }
        let data: Data, lines: [ChatLine]
        do { (data, lines) = try validated(file) }
        catch { (data, lines) = try validated(replica); try replaceDamaged(file, with: data, cache: cache) }
        let replicaInfo = try? fingerprint(replica)
        if replicaInfo == nil || cache.fingerprints[cacheKey(replica)] != replicaInfo {
            if let copy = try? Data(contentsOf: replica), digest(copy) == page.sha256 { cache.fingerprints[cacheKey(replica)] = replicaInfo }
            else { try replaceDamaged(replica, with: data, cache: cache) }
        }
        return lines
    }
    static func restore(_ index: Index, directory: URL, cache: Cache, open: (Data) throws -> Data) throws -> AppSnapshot {
        guard index.format == format, index.schemaVersion <= AppSnapshot.currentSchemaVersion,
              index.snapshot.chat.isEmpty, index.snapshot.conversations.isEmpty,
              index.active.id == index.snapshot.currentConversationID else { throw SnapshotVersionError() }
        if !index.pages.isEmpty {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw PuddleError("The transcript directory is not a regular folder.") }
        }
        var total = 0
        for page in index.pages {
            guard page.bytes > 0, page.bytes <= maximumBytes - total else { throw PuddleError("The saved workspace exceeds its transcript size limit.") }
            total += page.bytes
        }
        var entries: [UUID: CachedTranscript] = [:]
        func conversation(_ reference: Transcript) throws -> Conversation {
            var lines: [ChatLine] = []
            for page in reference.pages { lines += try read(page, directory: directory, cache: cache, open: open) }
            let value = Conversation(id: reference.id, createdAt: reference.createdAt, lines: lines)
            entries[value.id] = CachedTranscript(value: value, reference: reference)
            return value
        }
        var result = index.snapshot
        result.conversations = try index.conversations.map(conversation)
        result.chat = try conversation(index.active).lines
        cache.transcripts = entries
        cache.committedNames = Set(index.pages.map(\.file)); cache.needsSweep = true
        return result
    }
    static func prepare(_ state: AppSnapshot, directory: URL, cache: Cache,
                        seal: (Data) throws -> Data, open: (Data) throws -> Data) throws -> Prepared {
        let fm = FileManager.default, recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try ensureDirectory(directory); try ensureDirectory(recovery)
        var created: [URL] = [], entries: [UUID: CachedTranscript] = [:], total = 0
        do {
            func reference(_ value: Conversation) throws -> Transcript {
                let previous = cache.transcripts[value.id]
                if let previous, previous.value == value {
                    for page in previous.reference.pages {
                        let file = try location(page, directory: directory), info = try? fingerprint(file)
                        let replica = recovery.appendingPathComponent(page.file), copy = try? fingerprint(replica)
                        if info == nil || copy == nil || cache.fingerprints[page.file] != info || cache.fingerprints[cacheKey(replica)] != copy { _ = try read(page, directory: directory, cache: cache, open: open) }
                    }
                    entries[value.id] = previous
                    return previous.reference
                }
                var pages: [Page] = []
                for start in stride(from: 0, to: value.lines.count, by: pageSize) {
                    let end = min(start + pageSize, value.lines.count)
                    if let previous, start / pageSize < previous.reference.pages.count,
                       previous.value.lines.count >= end, previous.value.lines[start..<end] == value.lines[start..<end] {
                        let page = previous.reference.pages[start / pageSize]
                        // A partial page must not be reused after its message count changed.
                        let oldEnd = min(start + pageSize, previous.value.lines.count)
                        if end == oldEnd {
                            let info = try? fingerprint(try location(page, directory: directory)), replica = recovery.appendingPathComponent(page.file), copy = try? fingerprint(replica)
                            if info == nil || copy == nil || cache.fingerprints[page.file] != info || cache.fingerprints[cacheKey(replica)] != copy { _ = try read(page, directory: directory, cache: cache, open: open) }
                            pages.append(page); continue
                        }
                    }
                    let plain = try JSONEncoder().encode(Array(value.lines[start..<end]))
                    guard plain.count <= maximumBytes else { throw PuddleError("This transcript exceeds the workspace size limit.") }
                    let data = try seal(plain), name = UUID().uuidString + ".vault", file = directory.appendingPathComponent(name)
                    try data.write(to: file, options: [.atomic, .completeFileProtection])
                    created.append(file)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    cache.fingerprints[name] = try fingerprint(file)
                    let replica = recovery.appendingPathComponent(name)
                    try data.write(to: replica, options: [.atomic, .completeFileProtection]); created.append(replica)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replica.path)
                    cache.fingerprints[cacheKey(replica)] = try fingerprint(replica)
                    pages.append(Page(file: name, sha256: digest(data), bytes: plain.count))
                }
                let result = Transcript(id: value.id, createdAt: value.createdAt, pages: pages)
                entries[value.id] = CachedTranscript(value: value, reference: result)
                return result
            }
            let conversations = try state.conversations.map(reference)
            let active = try reference(Conversation(id: state.currentConversationID, createdAt: state.currentConversationCreatedAt, lines: state.chat))
            var hot = state; hot.conversations = []; hot.chat = []
            let index = Index(format: format, schemaVersion: AppSnapshot.currentSchemaVersion, snapshot: hot, conversations: conversations, active: active)
            let data = try JSONEncoder().encode(index)
            total = data.count
            for page in index.pages {
                guard page.bytes <= maximumBytes - total else { throw PuddleError("This workspace exceeds the encrypted storage limit. Export and remove older large transcripts before saving more.") }
                total += page.bytes
            }
            guard total <= maximumBytes else { throw PuddleError("This workspace exceeds the encrypted storage limit.") }
            return Prepared(data: data, index: index, transcripts: entries, created: created)
        } catch {
            for file in created { try? fm.removeItem(at: file); cache.fingerprints.removeValue(forKey: cacheKey(file)) }
            throw error
        }
    }
    /// Keep both committed generations. Never collect pages that may belong to
    /// a preserved damaged index; recovery evidence must remain recoverable.
    static func collect(in directory: URL, keeping names: Set<String>, cache: Cache) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "vault" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file); cache.fingerprints.removeValue(forKey: cacheKey(file))
        }
    }
    static func collectKnown(_ candidates: Set<String>, in directory: URL, keeping names: Set<String>, cache: Cache) {
        for name in candidates where !names.contains(name) {
            let file = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: file); cache.fingerprints.removeValue(forKey: cacheKey(file))
        }
    }
}
