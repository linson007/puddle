import Foundation
import Network
import XCTest
@testable import PuddleCore

private final class SecurityHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "puddle.security-http-fixture")
    private let lock = NSLock()
    private var count = 0
    let response: Data
    let keepOpen: Bool
    var requests: Int { lock.withLock { count } }
    init(response: String, keepOpen: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        self.response = Data(response.utf8)
        self.keepOpen = keepOpen
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue); receive(connection, bytes: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture")!)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 32_768 else { connection.cancel(); return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                if complete { connection.cancel() } else { receive(connection, bytes: bytes) }; return
            }
            lock.withLock { self.count += 1 }
            connection.send(content: response, completion: .contentProcessed { _ in
                if self.keepOpen { self.queue.asyncAfter(deadline: .now() + 3) { connection.cancel() } }
                else { connection.cancel() }
            })
        }
    }
    func stop() { listener.cancel() }
}
final class HTTPBoundaryTests: XCTestCase {
    func testConcreteStreamingTransportRejectsDeclaredOversizeBeforeReadingBody() async throws {
        let server = try SecurityHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 1024), keepOpen: true)
        let url = try await server.start(); defer { server.stop() }
        do { _ = try await URLSessionTransport().sendBounded(URLRequest(url: url), maximumBytes: 64, until: nil); XCTFail("Declared oversized body accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("size limit"), error.localizedDescription) }
        XCTAssertEqual(server.requests, 1)
    }
    func testConcreteStreamingTransportCapsChunkedResponseWithoutContentLength() async throws {
        let body = String(repeating: "x", count: 2048)
        let server = try SecurityHTTPServer(response: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n800\r\n\(body)\r\n0\r\n\r\n")
        let url = try await server.start(); defer { server.stop() }
        do { _ = try await URLSessionTransport().sendBounded(URLRequest(url: url), maximumBytes: 64, until: nil); XCTFail("Unbounded chunked body accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("size limit"), error.localizedDescription) }
        XCTAssertEqual(server.requests, 1)
    }
    func testConcreteTransportNeverFollowsRedirectWithAuthorizationOrBody() async throws {
        let destination = try SecurityHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let sink = try await destination.start(); defer { destination.stop() }
        let redirect = try SecurityHTTPServer(response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(sink.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let url = try await redirect.start(); defer { redirect.stop() }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data("Synthetic private prompt".utf8)
        request.setValue("Bearer synthetic-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSessionTransport().sendBounded(request, maximumBytes: 64, until: nil)
        XCTAssertEqual(response.statusCode, 307); XCTAssertEqual(redirect.requests, 1); XCTAssertEqual(destination.requests, 0)
    }
}
