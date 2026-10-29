import Foundation

public protocol ChromeCommanding: Sendable {
    func command(_ method: String, parameters: Data, sessionID: String?) async throws -> Data
    func close() async
}

public protocol ChromeWire: Sendable {
    func send(_ message: String) async throws
    func receive() async throws -> Data
    func close() async
}

public enum ChromeJSON {
    public static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PuddleError("The managed browser returned an invalid response.") }
        return value
    }
    public static func endpoint(portFile: String) throws -> URL {
        let lines = portFile.components(separatedBy: .newlines)
        guard lines.count >= 2, let port = Int(lines[0]), (1024...65535).contains(port),
              lines[1].range(of: #"^/devtools/browser/[A-Za-z0-9-]{8,80}$"#, options: .regularExpression) != nil,
              let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
            throw PuddleError("The dedicated Meet browser did not provide a valid local control endpoint.")
        }
        return url
    }
}

/// One receiver handles responses and ignores unrelated browser events.
public actor ChromeDevTools: ChromeCommanding {
    private let wire: any ChromeWire
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var sequence = 0
    private var closed = false
    private let timeout: Double

    public init(endpoint: URL, timeout: Double = 8) throws {
        guard endpoint.scheme == "ws", endpoint.host == "127.0.0.1", let port = endpoint.port, (1024...65535).contains(port),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.range(of: #"^/devtools/browser/[A-Za-z0-9-]{8,80}$"#, options: .regularExpression) != nil else {
            throw PuddleError("Browser control is limited to Puddle's local Meet browser.")
        }
        self.wire = BrowserWebSocket(endpoint: endpoint, timeout: timeout); self.timeout = timeout
    }
    public init(wire: any ChromeWire, timeout: Double = 8) { self.wire = wire; self.timeout = timeout }
    public func command(_ method: String, parameters: Data = Data("{}".utf8), sessionID: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw PuddleError("The managed browser connection is closed.") }
        if reader == nil { reader = Task { [weak self] in await self?.receive() } }
        sequence += 1; let id = sequence
        var body: [String: Any] = ["id": id, "method": method, "params": try ChromeJSON.object(parameters)]
        if let sessionID { body["sessionId"] = sessionID }
        let message = String(decoding: try ChromeJSON.data(body), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.timeout ?? 8)) } catch { return }
                    await self?.fail(id, message: "The managed browser did not respond. Check its window and retry.")
                }
                Task { [weak self] in await self?.sendPending(id, message: message) }
            }
        } onCancel: { [weak self] in Task { await self?.cancel(id) } }
    }
    private func receive() async {
        do {
            while !closed, !Task.isCancelled {
                let data = try await wire.receive()
                let response = try ChromeJSON.object(data)
                guard let id = response["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
                deadlines.removeValue(forKey: id)?.cancel()
                if response["error"] != nil { continuation.resume(throwing: PuddleError("The browser rejected a Meet automation command. Update Chrome or continue joining manually.")) }
                else { continuation.resume(returning: try ChromeJSON.data(response["result"] as? [String: Any] ?? [:])) }
            }
        } catch { if !closed { finishPending(message: "The dedicated Meet browser disconnected. Check its window before retrying."); await wire.close() } }
    }
    private func sendPending(_ id: Int, message: String) async {
        guard !closed, pending[id] != nil else { return }
        do { try await wire.send(message) }
        catch { fail(id, message: "The managed browser connection failed. Reopen the Meet browser and retry.") }
    }
    private func fail(_ id: Int, message: String) {
        deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: PuddleError(message))
    }
    private func cancel(_ id: Int) {
        deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    private func finishPending(message: String) {
        closed = true
        let waiting = pending; pending = [:]; deadlines.values.forEach { $0.cancel() }; deadlines = [:]
        for continuation in waiting.values { continuation.resume(throwing: PuddleError(message)) }
    }
    public func close() async {
        finishPending(message: "The managed browser connection was closed.")
        reader?.cancel(); reader = nil; await wire.close()
    }
}

private final class BrowserWebSocket: ChromeWire, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(endpoint: URL, timeout: Double) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration, delegate: BrowserSocketPolicy(), delegateQueue: nil)
        self.session = session; socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 1_000_000; socket.resume()
    }
    func send(_ message: String) async throws { try await socket.send(.string(message)) }
    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .data(let bytes): return bytes
        case .string(let value): return Data(value.utf8)
        @unknown default: throw PuddleError("The browser returned an unsupported message.")
        }
    }
    func close() { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

private final class BrowserSocketPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
