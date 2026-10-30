import Darwin
import Foundation

public struct ProjectGitFile: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
}
public struct ProjectGitStatus: Codable, Sendable {
    public let branch: String
    public let commit: String
    public let files: [ProjectGitFile]
    public let excluded: Int
    public let incomplete: Bool
    public let checkedAt: Date
}
public struct ProjectGitDiff: Codable, Sendable {
    public let path: String
    public let staged: Bool
    public let text: String
    public let shortened: Bool
    public let checkedAt: Date
    public let scope: String
}

private struct GitOutput: Sendable { let data: Data; let status: Int32; let shortened: Bool }

/// Only fixed read commands use this runner. No shell, hooks, external diff, textconv or user argv.
private final class GitReadProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var output = Data()
    private var shortened = false
    private var timedOut = false
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); stop(process) }
    private func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    func run(_ arguments: [String], at directory: URL, limit: Int) throws -> GitOutput {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git"); task.currentDirectoryURL = directory
        task.arguments = ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-c", "core.quotePath=false"] + arguments
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_PAGER": "cat", "GIT_ALLOW_PROTOCOL": "", "GIT_NO_LAZY_FETCH": "1", "GIT_LITERAL_PATHSPECS": "1"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            lock.lock()
            let data = handle.availableData
            let remaining = max(0, limit - output.count)
            output.append(data.prefix(remaining)); if data.count > remaining { shortened = true }; lock.unlock()
        }
        lock.lock()
        if cancelled { lock.unlock(); pipe.fileHandleForReading.readabilityHandler = nil; throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); pipe.fileHandleForReading.readabilityHandler = nil; throw PuddleError("Git could not start. Install the macOS command line tools to use repository status and diffs.") }
        let timeout = DispatchWorkItem { [self] in
            guard task.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock(); stop(task)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        task.waitUntilExit(); timeout.cancel()
        // The sole child is Git with helpers disabled; after exit there are no writer descendants.
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        let remaining = max(0, limit - output.count); output.append(tail.prefix(remaining))
        shortened = shortened || tail.count > remaining
        if cancelled { throw CancellationError() }
        if timedOut { throw PuddleError("Git inspection exceeded five seconds. Try a smaller working tree.") }
        return GitOutput(data: output, status: task.terminationStatus, shortened: shortened)
    }
}

public enum ProjectGit {
    private static func run(_ arguments: [String], at directory: URL, limit: Int = 128_000) async throws -> GitOutput {
        let process = GitReadProcess()
        let worker = Task.detached(priority: .userInitiated) { try process.run(arguments, at: directory, limit: limit) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { process.cancel(); worker.cancel() }
    }
    private static func root(_ files: ProjectFiles) async throws -> URL {
        let root = try files.verifiedRoot()
        let output = try await run(["rev-parse", "--show-toplevel"], at: root)
        guard output.status == 0, let path = String(data: output.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == root.path else {
            throw PuddleError("Git inspection needs the repository's root folder. Source browsing also works for folders without Git.")
        }
        return root
    }
    public static func status(_ files: ProjectFiles) async throws -> ProjectGitStatus {
        let directory = try await root(files)
        let branch = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: directory, limit: 1000)
        let head = try await run(["rev-parse", "--short=12", "HEAD"], at: directory, limit: 1000)
        let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=all"], at: directory)
        guard output.status == 0 else { throw PuddleError("Git status could not be read. Check the repository in your Git client.") }
        var entries = String(decoding: output.data, as: UTF8.self).components(separatedBy: "\0")
        if output.shortened { entries.removeLast() }
        var result: [ProjectGitFile] = [], excluded = 0, index = 0
        while index < entries.count {
            let entry = entries[index]; index += 1
            guard entry.count >= 4 else { continue }
            let status = String(entry.prefix(2)), path = String(entry.dropFirst(3))
            if status.contains("R") || status.contains("C") { index += 1 }
            if ProjectFiles.permits(path) { result.append(ProjectGitFile(path: path, status: status)) } else { excluded += 1 }
        }
        return ProjectGitStatus(branch: branch.status == 0 ? String(String(decoding: branch.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) : "Detached HEAD",
            commit: head.status == 0 ? String(decoding: head.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "No commits yet",
            files: Array(result.prefix(200)), excluded: excluded, incomplete: output.shortened || result.count > 200, checkedAt: Date())
    }

    private static func blob(_ reference: String, path: String, at root: URL) async throws -> String {
        if reference.hasPrefix("HEAD:") {
            let head = try await run(["rev-parse", "--verify", "HEAD"], at: root, limit: 1000)
            if head.status != 0 { return "" } // An unborn repository has an empty HEAD baseline.
        }
        let presence = try await run(reference.hasPrefix("HEAD:") ? ["ls-tree", "-z", "HEAD", "--", path] : ["ls-files", "--stage", "-z", "--", path], at: root, limit: 8000)
        guard presence.status == 0, !presence.shortened else { throw PuddleError("The Git baseline could not be inspected.") }
        if presence.data.isEmpty { return "" }
        let mode = String(decoding: presence.data.prefix(6), as: UTF8.self)
        guard ["100644", "100755"].contains(mode) else { throw PuddleError("Only regular source blobs can be compared; symbolic links and submodules are excluded.") }
        let output = try await run(["cat-file", "blob", reference], at: root, limit: ProjectFiles.maximumFileBytes + 1)
        guard output.status == 0 else { throw PuddleError("The Git blob could not be read. Resolve index conflicts or repository errors before comparing this path.") }
        guard !output.shortened, output.data.count <= ProjectFiles.maximumFileBytes, !output.data.contains(0),
              let text = String(data: output.data, encoding: .utf8), !ProjectFiles.containsCredential(text) else {
            throw PuddleError("The Git version is oversized, binary or contains a recognized credential pattern and was withheld.")
        }
        return text
    }
    public static func diff(_ files: ProjectFiles, path: String, staged: Bool) async throws -> ProjectGitDiff {
        guard ProjectFiles.permits(path) else { throw PuddleError("That path is outside the readable project source policy.") }
        let directory = try await root(files)
        let before = try await blob((staged ? "HEAD:" : ":") + path, path: path, at: directory)
        let after: String
        if staged { after = try await blob(":" + path, path: path, at: directory) }
        else { after = try files.content(path, allowMissing: true) ?? "" }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-diff-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (name, text) in [("before", before), ("after", after)] {
            let url = temporary.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw PuddleError("The temporary comparison could not be saved. Check available disk space; project files were untouched.")
            }
        }
        // Diff captured bytes, rather than reopening a mutable project path through an external tool.
        let output = try await run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--text", "--", "before", "after"], at: temporary, limit: 20_000)
        guard output.status == 0 || output.status == 1 else { throw PuddleError("The captured source versions could not be compared.") }
        let text = String(decoding: output.data, as: UTF8.self).components(separatedBy: "\n").map { line in
            if line == "diff --git a/before b/after" { return "diff --git a/\(path) b/\(path)" }
            if line == "--- a/before" { return "--- a/\(path)" }
            if line == "+++ b/after" { return "+++ b/\(path)" }
            return line
        }.joined(separator: "\n")
        return ProjectGitDiff(path: path, staged: staged, text: text.isEmpty ? "No text changes in this comparison." : text,
            shortened: output.shortened, checkedAt: Date(), scope: staged ? "Captured HEAD versus index text. Renames/modes/binaries are not represented by this text comparison." : "Captured index versus working-file text. New files use an empty baseline. Renames/modes/binaries are not represented. No tests were run or files changed.")
    }
}
