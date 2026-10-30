import Darwin
import Foundation

public struct ProjectFile: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int
}
public struct ProjectFileList: Codable, Sendable {
    public let files: [ProjectFile]
    public let skipped: Int
    public let incomplete: Bool
    public let scope: String
}
public struct ProjectFileExcerpt: Codable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let text: String
    public let shortened: Bool
}
public struct ProjectSearchMatch: Codable, Identifiable, Sendable {
    public var id: String { "\(path):\(line)" }
    public let path: String
    public let line: Int
    public let text: String
}
public struct ProjectSearchResult: Codable, Sendable {
    public let matches: [ProjectSearchMatch]
    public let filesSearched: Int
    public let incomplete: Bool
    public let scope: String
}

/// Files are opened relative to a held directory descriptor. Symlinks are refused at every component.
/// This avoids both traversal and a symlink-swap between checking a path and reading its bytes.
public final class ProjectFiles: @unchecked Sendable {
    public static let maximumFileBytes = 512 * 1024
    private let rootFD: Int32
    private let root: URL
    private let canonical: URL
    private let scoped: Bool
    private static let ignoredDirectories: Set<String> = [".git", ".hg", ".svn", ".ssh", ".aws", ".gnupg", ".codex", ".agents", ".venv", "venv", "node_modules", "vendor", "build", ".build", "dist", "target", "deriveddata", ".next", ".turbo", ".cache", "__pycache__"]
    private static let textExtensions: Set<String> = ["swift", "c", "h", "cpp", "hpp", "cc", "m", "mm", "metal", "rs", "go", "py", "pyi", "js", "jsx", "ts", "tsx", "json", "toml", "yaml", "yml", "xml", "html", "css", "scss", "md", "txt", "sh", "bash", "zsh", "sql", "java", "kt", "kts", "rb", "php", "ex", "exs", "erl", "scala", "cs", "fs", "vue", "svelte", "graphql", "proto", "cmake", "gradle", "ini", "cfg", "conf", "lock", "mod", "sum", "dockerfile"]

    public init(project: DeveloperProject) throws {
        _ = try project.validated()
        let selected = try project.folder()
        scoped = selected.startAccessingSecurityScopedResource()
        root = selected
        canonical = selected.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != "/", canonical.path != NSHomeDirectory() else {
            if scoped { selected.stopAccessingSecurityScopedResource() }
            throw PuddleError("Choose a project folder, rather than your entire home folder or disk.")
        }
        rootFD = open(canonical.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else {
            if scoped { selected.stopAccessingSecurityScopedResource() }
            throw PuddleError("The project folder is unavailable. Reconnect it in Developer.")
        }
    }
    deinit { close(rootFD); if scoped { root.stopAccessingSecurityScopedResource() } }

    public static func permits(_ path: String, directory: Bool = false) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), path.count <= 2048,
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        for component in parts {
            let value = component.lowercased()
            if ignoredDirectories.contains(value) || value.hasPrefix(".env") || value.hasPrefix("client_secret") ||
                value.contains("credentials") || value == "secrets" || value.hasPrefix("secrets.") ||
                value.hasPrefix("id_rsa") || value.hasPrefix("id_ed25519") || value.hasSuffix(".pem") ||
                value.hasSuffix(".key") || value.hasSuffix(".p12") || value.hasSuffix(".pfx") || value.hasSuffix(".keystore") { return false }
        }
        guard !directory else { return true }
        let name = parts.last!.lowercased()
        return ["makefile", "dockerfile", "gemfile", "rakefile", "license", ".gitignore", ".gitattributes", ".editorconfig"].contains(name) || textExtensions.contains((name as NSString).pathExtension)
    }

    private func descriptor(_ path: String, directory: Bool = false, allowMissing: Bool = false) throws -> Int32 {
        guard Self.permits(path, directory: directory) else { throw PuddleError("That path is outside the readable project source policy.") }
        let parts = path.split(separator: "/").map(String.init)
        var current = dup(rootFD)
        guard current >= 0 else { throw PuddleError("Project folder access is unavailable.") }
        for (index, component) in parts.enumerated() {
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | ((index < parts.count - 1 || directory) ? O_DIRECTORY : 0)
            let next = openat(current, component, flags)
            let missing = next < 0 && errno == ENOENT && index == parts.count - 1 && allowMissing
            close(current)
            if missing { return -1 }
            guard next >= 0 else { throw PuddleError("The file is unavailable, symbolic, or outside the selected project.") }
            current = next
        }
        return current
    }

    public func inventory(matching query: String = "", limit: Int = 200) throws -> ProjectFileList {
        var files: [ProjectFile] = [], skipped = 0, visited = 0, incomplete = false
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 20, visited < 20_000 else { incomplete = true; return }
            let scanFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard scanFD >= 0 else { skipped += 1; return }
            guard let directory = fdopendir(scanFD) else { close(scanFD); skipped += 1; return }
            defer { closedir(directory) }
            var names: [String] = []
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
                if names.count >= 20_000 { incomplete = true; break }
            }
            for name in names.sorted() {
                try Task.checkCancellation(); visited += 1
                if visited > 20_000 || files.count >= max(1, min(10_000, limit)) { incomplete = true; return }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { skipped += 1; continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    guard Self.permits(path, directory: true) else { skipped += 1; continue }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { skipped += 1; continue }
                    defer { close(child) }
                    try walk(child, prefix: path, depth: depth + 1)
                } else if kind == S_IFREG, Self.permits(path), info.st_size <= Self.maximumFileBytes {
                    if query.isEmpty || path.localizedCaseInsensitiveContains(query) { files.append(ProjectFile(path: path, bytes: Int(info.st_size))) }
                } else { skipped += 1 }
            }
        }
        try walk(rootFD, prefix: "", depth: 0)
        return ProjectFileList(files: files, skipped: skipped, incomplete: incomplete,
            scope: "Source files only; symlinks, common generated/private folders, credential filenames, binaries and files over 512 KB are excluded. Gitignore rules are not applied. Traversal and result limits may omit files.")
    }

    public func content(_ path: String, allowMissing: Bool = false) throws -> String? {
        let fd = try descriptor(path, allowMissing: allowMissing)
        if fd < 0 { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maximumFileBytes else {
            throw PuddleError("Only regular source files up to 512 KB can be read.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw PuddleError("The source file could not be read.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileBytes else { throw PuddleError("The source file grew beyond the 512 KB limit.") }
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw PuddleError("This file is not supported UTF-8 source text.") }
        guard !Self.containsCredential(text) else { throw PuddleError("This source contains a recognized credential pattern and was withheld. Remove the credential before sharing it with the assistant.") }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    public func read(_ path: String, startLine: Int = 1, lineCount: Int = 120) throws -> ProjectFileExcerpt {
        guard startLine >= 1, (1...160).contains(lineCount) else { throw PuddleError("Read from line 1 or later, with 1–160 lines per request.") }
        let lines = try content(path)!.components(separatedBy: "\n")
        guard startLine <= lines.count else { throw PuddleError("The requested line is beyond this file's \(lines.count) lines.") }
        let end = min(lines.count, startLine + lineCount - 1)
        var excerpt = "", last = startLine - 1, shortened = end < lines.count
        for index in (startLine - 1)..<end {
            let line = "\(index + 1): \(lines[index])\n"
            if excerpt.count + line.count > 14_000 {
                if excerpt.isEmpty { excerpt = String(line.prefix(14_000)); last = index + 1 }
                shortened = true; break
            }
            excerpt += line; last = index + 1
        }
        return ProjectFileExcerpt(path: path, startLine: startLine, endLine: last, totalLines: lines.count, text: excerpt, shortened: shortened)
    }

    public func search(_ query: String) throws -> ProjectSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200 else { throw PuddleError("Search for 1–200 characters of literal source text.") }
        let list = try inventory(limit: 2000)
        var matches: [ProjectSearchMatch] = [], searched = 0, bytes = 0, incomplete = list.incomplete
        for file in list.files {
            try Task.checkCancellation()
            bytes += file.bytes
            if bytes > 8 * 1024 * 1024 { incomplete = true; break }
            let value: String
            do { value = try content(file.path)! } catch is CancellationError { throw CancellationError() } catch { incomplete = true; continue }
            searched += 1
            for (index, line) in value.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(ProjectSearchMatch(path: file.path, line: index + 1, text: String(line.prefix(350))))
                if matches.count == 30 { incomplete = true; break }
            }
            if matches.count == 30 { break }
        }
        return ProjectSearchResult(matches: matches, filesSearched: searched, incomplete: incomplete, scope: list.scope + " Literal case-insensitive search; at most 2,000 files, 8 MB and 30 matching lines.")
    }

    public static func containsCredential(_ text: String) -> Bool {
        let patterns = [#"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#, #"\bAKIA[0-9A-Z]{16}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,
            #"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b"#,
            #"(?i)(?:password|api[_-]?key|client[_-]?secret|access[_-]?token)\s*[=:]\s*["'][^"'\s]{12,}["']"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    public func verifiedRoot() throws -> URL {
        var held = stat(), current = stat()
        guard fstat(rootFD, &held) == 0, lstat(canonical.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw PuddleError("The project folder moved or changed while reading it. Reconnect the folder.")
        }
        return canonical
    }
}
