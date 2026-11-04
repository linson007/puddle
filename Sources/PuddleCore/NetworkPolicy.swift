import Foundation
import os

public final class NetworkPolicy: Sendable {
    private struct State: Sendable { var external = true; var revision = UUID() }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public func allowExternalConnections(_ allow: Bool) {
        state.withLock { if $0.external != allow { $0.revision = UUID() }; $0.external = allow }
    }
    public func check(_ url: URL?) throws { _ = try permit(url) }
    fileprivate func currentRevision() -> UUID { state.withLock { $0.revision } }
    fileprivate func permit(_ url: URL?) throws -> UUID? {
        guard let host = url?.host?.lowercased() else { throw PuddleError("The request has no valid host.") }
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return nil }
        return try state.withLock {
            guard $0.external else { throw PuddleError("External connections are paused. Local AI remains available.") }
            return $0.revision
        }
    }
    fileprivate func validate(_ permit: UUID?) throws {
        guard let permit else { return }
        guard state.withLock({ $0.external && $0.revision == permit }) else {
            throw PuddleError("This external request was interrupted by a privacy or connection-policy change. Its response was discarded.")
        }
    }
}

public struct PolicyTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let policy: NetworkPolicy
    private let operationRevision: UUID?
    public init(base: any HTTPTransport, policy: NetworkPolicy, bindToCurrentPolicy: Bool = false) {
        self.base = base; self.policy = policy
        operationRevision = bindToCurrentPolicy ? policy.currentRevision() : nil
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url), result = try await base.send(request)
        try policy.validate(permit); return result
        } catch { PuddleDiagnostics.failure(.network, "Request failed", error); throw error }
    }
    public func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        do {
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url), result = try await base.sendBounded(request, maximumBytes: maximumBytes, until: until)
        try policy.validate(permit); return result
        } catch { PuddleDiagnostics.failure(.network, "Request failed", error); throw error }
    }
    public func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        do {
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url)
        let response = try await base.stream(request) { line in try policy.validate(permit); try await onLine(line) }
        try policy.validate(permit); return response
        } catch { PuddleDiagnostics.failure(.network, "Stream failed", error); throw error }
    }
}
