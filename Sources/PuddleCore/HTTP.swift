import Foundation

public struct HTTPServiceError: LocalizedError, Sendable {
    public let statusCode: Int
    public let retryAfter: TimeInterval?
    public let message: String
    public var errorDescription: String? { message }
}

public struct RetryingTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let wait: @Sendable (TimeInterval) async throws -> Void
    public init(base: any HTTPTransport, wait: @escaping @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }) { self.base = base; self.wait = wait }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await retry(request) { try await base.send(request) }
    }
    public func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        try await retry(request) { try await base.sendBounded(request, maximumBytes: maximumBytes, until: until) }
    }
    private func retry(_ request: URLRequest, operation: () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        // Retry only reads. Token exchanges and model generations are never replayed.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let result = try await operation()
            guard request.httpMethod == "GET", [429, 500, 502, 503, 504].contains(result.1.statusCode), attempt < 2 else { return result }
            let delay = retryDelay(result.1) ?? pow(2, Double(attempt))
            guard delay <= 30 else { return result } // Let the polling worker honor a longer delay.
            try await wait(delay)
        }
        throw PuddleError("Retry limit reached.")
    }
}

func retryDelay(_ response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value) { return max(0, seconds) }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse)
    func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    public func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        let result = try await send(request)
        guard result.0.count <= maximumBytes else { throw PuddleError("The service response exceeded its size limit. Narrow the request.") }
        return result
    }
    public func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request)
        try checkHTTP(response, data: data, service: "Splash")
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            try Task.checkCancellation(); try await onLine(line)
        }
        return response
    }
}

/// Redirects are rejected: OAuth/Gmail use fixed HTTPS hosts, and email text
/// sent to the local inference server must never follow a redirect elsewhere.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw PuddleError("The service returned an unreadable response.")
        }
        return (data, response)
    }

    public func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw PuddleError("The service returned an unreadable response.") }
        guard response.expectedContentLength <= Int64(maximumBytes) else { bytes.task.cancel(); throw PuddleError("The service response exceeded its size limit. Narrow the request.") }
        var data = Data()
        // Cancel the stream after its matching RPC result, even when the SSE connection stays open.
        defer { bytes.task.cancel() }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw PuddleError("The service response exceeded its size limit. Narrow the request.") }
            data.append(byte)
            if byte == 10, until?(data, response) == true { break }
        }
        return (data, response)
    }

    public func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PuddleError("Unreadable streaming response.") }
        if !(200..<300).contains(response.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count >= 65536 { break } }
            try checkHTTP(response, data: data, service: "Splash")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 256_000 else { throw PuddleError("The streaming response exceeded its event limit.") }
            try await onLine(line)
        }
        return response
    }

}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public func formBody(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return Data(fields.sorted { $0.key < $1.key }.map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&").utf8)
}

func checkHTTP(_ response: HTTPURLResponse, data: Data, service: String) throws {
    guard (200..<300).contains(response.statusCode) else {
        if response.statusCode == 401 {
            throw PuddleError("\(service) sign-in expired. Reconnect in Settings.")
        }
        if response.statusCode == 429 {
            throw HTTPServiceError(statusCode: 429, retryAfter: retryDelay(response), message: "\(service) is rate limiting requests. Puddle will back off before its next automatic check.")
        }
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
        throw HTTPServiceError(statusCode: response.statusCode, retryAfter: retryDelay(response),
                               message: "\(service) returned HTTP \(response.statusCode). \(detail ?? "Try again, or check Settings.")")
    }
}
