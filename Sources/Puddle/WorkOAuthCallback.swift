import AppKit
import Foundation
import Network
import PuddleCore

/// A short-lived callback receiver on an ephemeral IPv4 loopback port.
@MainActor final class WorkOAuthCallback {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.puddle.work-oauth")
    private var ready: CheckedContinuation<URL, Error>?
    private var completion: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var attempt: (any BrowserOAuthAttempt)?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any); self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!); self.ready = nil
                    self.timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(300)) } catch { return }
                        self?.finish(.failure(PuddleError("Browser sign-in timed out. Connect again when ready.")))
                    }
                case .failed: self.ready?.resume(throwing: PuddleError("The local sign-in callback could not start. Check firewall settings.")); self.ready = nil
                default: break
                }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection; connection.start(queue: self.queue)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10)); self?.connections.removeValue(forKey: id)?.cancel()
                }
                self.receive(connection, id: id, accumulated: Data())
            } }
            listener.start(queue: queue)
        }
    }
    func wait(for attempt: any BrowserOAuthAttempt) async throws -> String {
        self.attempt = attempt
        guard NSWorkspace.shared.open(attempt.authorizationURL) else { throw PuddleError("The browser could not open sign-in." ) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) } else { completion = continuation }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { ready?.resume(throwing: CancellationError()); ready = nil; finish(.failure(CancellationError())); close() }
    func close() { timeout?.cancel(); listener?.cancel(); listener = nil; for connection in connections.values { connection.cancel() }; connections = [:] }
    private func finish(_ result: Result<String, Error>) { guard self.result == nil else { return }; self.result = result; completion?.resume(with: result); completion = nil }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in Task { @MainActor in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated; if let data { bytes.append(data) }
            guard bytes.count <= 8192, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, id: id, accumulated: bytes) } else { self.connections.removeValue(forKey: id)?.cancel() }; return
            }
            let first = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/oauth/callback?"),
                  let attempt = self.attempt, let port = self.listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(first[1])") else { self.respond(connection, id: id, success: false); return }
            // A guessed state must not cancel an unrelated authorization attempt.
            let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
            guard states.count == 1, states[0].value == attempt.state else { self.respond(connection, id: id, success: false); return }
            do { let code = try attempt.code(from: url); self.respond(connection, id: id, success: true); self.finish(.success(code)) }
            catch { self.respond(connection, id: id, success: false); self.finish(.failure(error)) }
        } }
    }
    private func respond(_ connection: NWConnection, id: UUID, success: Bool) {
        let text = success ? "Authorization received. Return to Puddle." : "Sign-in could not be verified. Return to Puddle and try again."
        let body = Data(text.utf8)
        var response = Data("HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8); response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in connection.cancel(); Task { @MainActor in self?.connections[id] = nil } })
    }
}
