import Darwin
import Foundation

/// Publish only after flushing file contents, then persist the directory entry.
enum DurableFile {
    enum Stage { case beforeRename, afterRename }
    static func write(_ data: Data, to destination: URL, checkpoint: (Stage) throws -> Void = { _ in }) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".puddle-write-\(UUID())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure() }
                offset += written
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw failure() }
        try checkpoint(.beforeRename)
        guard rename(temporary.path, destination.path) == 0 else { throw failure() }
        try checkpoint(.afterRename)
        try syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure() }
    }
    private static func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Serializes independent processes while checking the loaded generation.
/// Never unlink this file: waiters must continue to lock the same inode.
final class WorkspaceFileLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent(".workspace.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PuddleError("Could not open the workspace ownership lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PuddleError("Another process is using this workspace. Close its operation and retry loading before saving.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
