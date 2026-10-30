import Darwin
import Foundation

public protocol CuaRPCTransport: Sendable {
    func rpc(_ method: String, parameters: ConnectorJSON, notification: Bool) async throws -> ConnectorJSON
    func close() async
}

/// One persistent, newline-delimited MCP connection. Never launches a shell.
public final class CuaStdioTransport: CuaRPCTransport, @unchecked Sendable {
    private let executable: URL
    private let queue = DispatchQueue(label: "app.puddle.cua-mcp")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var closed = false
    private let timeout: TimeInterval

    public init(executable: URL, timeout: TimeInterval = 30) {
        self.executable = executable; self.timeout = timeout
    }
    deinit { shutdown() }

    public func rpc(_ method: String, parameters: ConnectorJSON, notification: Bool = false) async throws -> ConnectorJSON {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let deadline = DispatchWorkItem { [weak self] in self?.shutdown() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    defer { deadline.cancel() }
                    do { continuation.resume(returning: try request(method, parameters: parameters, notification: notification)) }
                    catch { shutdown(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.shutdown() }
    }

    public func close() async { shutdown() }

    private func shutdown() {
        lock.lock(); closed = true; let task = process; let pipe = input; input = nil; lock.unlock()
        try? pipe?.close()
        guard let task, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    private func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw PuddleError("The Cua connection stopped. Start a new browser session before continuing.") }
        if process != nil { return }
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PuddleError("Choose the installed cua-driver executable in Browser.")
        }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable; task.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CUA_") && !$0.key.hasPrefix("DYLD_") && $0.key != "LD_PRELOAD"
        }
        environment["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        task.environment = environment
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try task.run() }
        catch { throw PuddleError("Cua Driver could not start. Check its installation and executable path.") }
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }

    private func request(_ method: String, parameters: ConnectorJSON, notification: Bool) throws -> ConnectorJSON {
        try start()
        let id = UUID().uuidString
        var envelope: [String: ConnectorJSON] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": parameters]
        if !notification { envelope["id"] = .string(id) }
        var data = ConnectorJSON.object(envelope).data
        guard data.count < 64_000 else { throw PuddleError("The browser request is too large.") }
        data.append(10)
        lock.lock(); let writer = closed ? nil : input; lock.unlock()
        guard let writer else { throw PuddleError("Cua stopped. Observe the browser before retrying any action.") }
        try writer.write(contentsOf: data)
        if notification { return .null }
        var received = 0
        while received < 4_000_000 {
            lock.lock(); let stopped = closed; lock.unlock()
            guard !stopped else { throw PuddleError("Cua stopped or timed out. Observe the browser before retrying an action.") }
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                if line.isEmpty { continue }
                let reply = try JSONDecoder().decode(ConnectorJSON.self, from: line)
                guard reply["jsonrpc"]?.string == "2.0" else { throw PuddleError("Cua returned an invalid MCP message.") }
                // Notifications are allowed; replies must match this request exactly.
                if reply["id"] == nil, reply["method"] != nil { continue }
                guard reply["id"]?.string == id else { throw PuddleError("Cua returned an unmatched MCP response.") }
                guard reply["error"] == nil, let result = reply["result"] else {
                    throw PuddleError("Cua refused this request. Check its version and permissions; observe before retrying an action.")
                }
                return result
            }
            guard let output else { throw PuddleError("Cua's output pipe is unavailable.") }
            // Foundation's read(upToCount:) can wait to fill a pipe read. A raw
            // read returns the currently available bytes of a persistent stream.
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw PuddleError("Cua disconnected or timed out. An in-flight action may have happened; start a new session and inspect before retrying.")
            }
            received += count; buffer.append(contentsOf: bytes.prefix(count))
        }
        throw PuddleError("Cua returned too much data. Use a narrower page query.")
    }
}
