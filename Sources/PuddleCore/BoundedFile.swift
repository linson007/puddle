import Darwin
import Foundation

/// Validate and read the same descriptor; refuse symlinks, devices and growing files.
enum BoundedFile {
    static let maximumWorkspaceBytes = 128 * 1024 * 1024
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    static func read(_ url: URL, maximumBytes: Int = maximumWorkspaceBytes) throws -> Data {
        var data = Data()
        try chunks(url, maximumBytes: maximumBytes) { data.append($0) }
        return data
    }
    static func chunks(_ url: URL, maximumBytes: Int, consume: (Data) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PuddleError("The saved file could not be opened safely. It was preserved.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw PuddleError("The saved file is not regular or exceeds its size limit. It was preserved.")
        }
        var total = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PuddleError("The saved file could not be read. It was preserved.") }
            if count == 0 { return }
            guard count <= maximumBytes - total else { throw PuddleError("The saved file grew beyond its size limit. It was preserved.") }
            total += count
            try consume(Data(buffer.prefix(count)))
        }
    }
}
