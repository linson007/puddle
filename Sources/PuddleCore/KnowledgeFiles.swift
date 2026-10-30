import Darwin
import Foundation
import UniformTypeIdentifiers

/// A selected source is held open. Every descendant is opened relative to that
/// descriptor, refusing links before inspecting or reading its bytes.
final class KnowledgeFiles {
    struct Captured {
        let data: Data
        let bytes: Int
        let modifiedAt: Date
    }
    let root: URL
    let isDirectory: Bool
    private let rootFD: Int32
    private static let denied: Set<String> = [".git", ".ssh", ".aws", ".codex", "node_modules", ".venv", "build", ".build", "dist", "target"]

    init(root: URL) throws {
        // Parent aliases such as /tmp -> /private/tmp are legitimate on macOS.
        // Never resolve the selected leaf itself or any descendant through a link.
        guard let resolved = realpath(root.deletingLastPathComponent().path, nil) else { throw PuddleError("The selected source folder is unavailable.") }
        let parentPath = String(cString: resolved); free(resolved)
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        self.root = parent.appendingPathComponent(root.lastPathComponent)
        let parentFD = try Self.directoryDescriptor(parentPath)
        defer { close(parentFD) }
        let fd = openat(parentFD, root.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        var info = stat()
        guard fd >= 0 else { throw PuddleError("Choose an ordinary local document or folder; symbolic links are excluded.") }
        guard fstat(fd, &info) == 0, [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else {
            close(fd); throw PuddleError("Choose an ordinary local document or folder.")
        }
        rootFD = fd; isDirectory = info.st_mode & S_IFMT == S_IFDIR
    }
    deinit { close(rootFD) }

    static func directoryDescriptor(_ canonicalPath: String) throws -> Int32 {
        guard canonicalPath.hasPrefix("/") else { throw PuddleError("The selected source folder is unavailable.") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw PuddleError("The selected source folder is unavailable.") }
        for component in canonicalPath.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            close(current)
            guard next >= 0 else { throw PuddleError("A source ancestor changed or contains a symbolic link. Choose the source again.") }
            current = next
        }
        return current
    }

    func inventory() throws -> (paths: [String], incomplete: Bool) {
        guard isDirectory else { return ([""], false) }
        var paths: [String] = [], visited = 0, incomplete = false
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32, visited < 5000, paths.count < 200 else { incomplete = true; return }
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard copy >= 0 else { incomplete = true; return }
            guard let directory = fdopendir(copy) else { close(copy); incomplete = true; return }
            defer { closedir(directory) }
            var names: [String] = []
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
                if names.count >= 5000 { incomplete = true; break }
            }
            for name in names.sorted() {
                try Task.checkCancellation(); visited += 1
                guard visited <= 5000, paths.count < 200 else { incomplete = true; return }
                guard !name.hasPrefix("."), !Self.denied.contains(name) else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
                guard info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if info.st_mode & S_IFMT == S_IFDIR {
                    let type = UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: .directory)
                    if type?.conforms(to: .package) == true || type?.conforms(to: .bundle) == true { continue }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { incomplete = true; continue }
                    defer { close(child) }
                    try walk(child, prefix: path, depth: depth + 1)
                } else if info.st_mode & S_IFMT == S_IFREG, LocalKnowledge.extensions.contains((name as NSString).pathExtension.lowercased()) { paths.append(path) }
            }
        }
        try walk(rootFD, prefix: "", depth: 0)
        return (paths, incomplete)
    }

    func capture(_ path: String, maximumBytes: Int) throws -> Captured {
        let fd: Int32
        if !isDirectory {
            guard path.isEmpty else { throw PuddleError("The requested document is outside the selected source.") }
            fd = dup(rootFD)
            guard fd >= 0, lseek(fd, 0, SEEK_SET) >= 0 else { if fd >= 0 { close(fd) }; throw PuddleError("The selected document could not be read.") }
        } else {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw PuddleError("The requested document is outside the selected source.") }
            var current = dup(rootFD)
            guard current >= 0 else { throw PuddleError("The selected folder could not be read.") }
            for (index, component) in parts.enumerated() {
                let next = openat(current, component, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
                close(current)
                guard next >= 0 else { throw PuddleError("A document path changed or contains a symbolic link. Choose the source again.") }
                current = next
            }
            fd = current
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= maximumBytes else { throw PuddleError("The document is not a regular file or exceeds its size limit.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PuddleError("The document could not be read.") }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else { throw PuddleError("The document grew beyond its size limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size, data.count == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw PuddleError("The document changed during its read. Refresh the source again.")
        }
        return Captured(data: data, bytes: data.count, modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000))
    }
}
