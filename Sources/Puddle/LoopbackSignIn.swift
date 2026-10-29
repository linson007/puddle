import AppKit
import Foundation
import Network
import PuddleCore

enum GoogleSignInBrowser: String, CaseIterable, Identifiable {
    case safari, system
    var id: String { rawValue }
    var title: String { self == .safari ? "Safari" : "Default browser" }
}

/// Google Desktop OAuth uses the system browser and a short-lived listener
/// bound only to 127.0.0.1. No web server or hosted callback is needed.
@MainActor
final class LoopbackSignIn {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.puddle.oauth")
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var flow: OAuthFlow?
    private var timeout: Task<Void, Never>?

    func signIn(client: GoogleClientConfiguration, session: GoogleSession, scopes: [String], browser: GoogleSignInBrowser = .safari) async throws {
        let flow = try OAuthFlow(scopes: scopes)
        self.flow = flow
        let redirect = try await start()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(PuddleError("Google sign-in timed out. Connect again when you’re ready.")))
        }
        defer { timeout?.cancel(); listener?.cancel(); listener = nil }
        try await open(flow.authorizationURL(client: client, redirect: redirect), in: browser)
        let code = try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { codeContinuation = continuation }
        }
        try Task.checkCancellation()
        try await session.exchange(code: code, flow: flow, redirect: redirect)
    }

    private func open(_ url: URL, in browser: GoogleSignInBrowser) async throws {
        if browser == .system {
            guard NSWorkspace.shared.open(url) else {
                throw PuddleError("Puddle could not open your default browser for Google sign-in.")
            }
            return
        }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw PuddleError("Safari could not be found. Choose Default browser in Settings → Connections and try again.")
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration)
        } catch {
            throw PuddleError("Safari could not open Google sign-in. Please try again, or choose Default browser in Settings → Connections.")
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
        readyContinuation?.resume(throwing: CancellationError()); readyContinuation = nil
        timeout?.cancel(); listener?.cancel()
    }

    private func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        self.readyContinuation?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                        self.readyContinuation = nil
                    case .failed:
                        self.readyContinuation?.resume(throwing: PuddleError("Puddle could not open its local sign-in callback. Check firewall settings and try again."))
                        self.readyContinuation = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection, accumulated: Data()) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        if accumulated.isEmpty { connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var accumulated = accumulated
                if let data { accumulated.append(data) }
                guard accumulated.count <= 8192, error == nil else { connection.cancel(); return }
                guard let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, accumulated: accumulated) }
                    else { connection.cancel() }
                    return
                }
                let pieces = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard pieces.count == 3, pieces[0] == "GET", pieces[1].hasPrefix("/"),
                      !pieces[1].hasPrefix("//"),
                      let url = URL(string: "http://127.0.0.1\(pieces[1])"), url.path == "/",
                      let flow = self.flow else {
                    self.respond(connection, success: false); return
                }
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" }
                guard state?.count == 1, state?.first?.value == flow.state else {
                    self.respond(connection, success: false); return
                }
                do {
                    let code = try flow.code(from: url)
                    self.respond(connection, success: true)
                    self.finish(.success(code))
                } catch {
                    self.respond(connection, success: false)
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, success: Bool) {
        let title = success ? "Return to Puddle" : "Sign-in could not be completed"
        let message = success ? "Google authorization received. You can close this tab and return to Puddle." : "Return to Puddle and try connecting again."
        let html = "<!doctype html><html><head><meta charset='utf-8'><title>Puddle</title></head><body style='font:18px system-ui;max-width:560px;margin:15vh auto;padding:24px'><h1>\(title)</h1><p>\(message)</p></body></html>"
        let body = Data(html.utf8)
        var response = Data("HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        codeContinuation?.resume(with: result); codeContinuation = nil
    }
}
