import Foundation

public final class NetworkPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var external = true
    private var revision = UUID()
    public init() {}
    public func allowExternalConnections(_ allow: Bool) { lock.withLock { if external != allow { revision = UUID() }; external = allow } }
    public func check(_ url: URL?) throws {
        _ = try permit(url)
    }
    fileprivate func currentRevision() -> UUID { lock.withLock { revision } }
    fileprivate func permit(_ url: URL?) throws -> UUID? {
        guard let host = url?.host?.lowercased() else { throw PuddleError("The request has no valid host.") }
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return nil }
        return try lock.withLock {
            guard external else { throw PuddleError("External connections are paused. Local AI remains available.") }
            return revision
        }
    }
    fileprivate func validate(_ permit: UUID?) throws {
        guard let permit else { return }
        guard lock.withLock({ external && revision == permit }) else { throw PuddleError("This external request was interrupted by a privacy or connection-policy change. Its response was discarded.") }
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
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url), result = try await base.send(request)
        try policy.validate(permit); return result
    }
    public func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url), result = try await base.sendBounded(request, maximumBytes: maximumBytes, until: until)
        try policy.validate(permit); return result
    }
    public func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        try policy.validate(operationRevision)
        let permit = try policy.permit(request.url)
        let response = try await base.stream(request) { line in try policy.validate(permit); try await onLine(line) }
        try policy.validate(permit); return response
    }
}
