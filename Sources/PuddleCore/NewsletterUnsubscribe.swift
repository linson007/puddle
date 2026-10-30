import Foundation
import Darwin

public struct NewsletterTarget: Codable, Equatable, Sendable {
    public let sender: String
    public let url: URL
    public init(sender: String, url: URL) { self.sender = sender; self.url = url }
    public func validate() throws {
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443,
              url.absoluteString.count <= 4096, sender.count <= 500, host.contains("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"), !host.hasSuffix(".localhost"),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else { throw PuddleError("This sender does not provide a supported public HTTPS one-click unsubscribe destination.") }
    }
    public static func from(sender: String, unsubscribe: String, post: String) -> Self? {
        guard post.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame,
              let expression = try? NSRegularExpression(pattern: "<(https://[^>]+)>", options: .caseInsensitive),
              let match = expression.firstMatch(in: unsubscribe, range: NSRange(unsubscribe.startIndex..., in: unsubscribe)),
              let range = Range(match.range(at: 1), in: unsubscribe), let url = URL(string: String(unsubscribe[range])) else { return nil }
        let target = Self(sender: sender, url: url); return (try? target.validate()) != nil ? target : nil
    }
}
public enum PublicNewsletterHost {
    public static func check(_ host: String) throws {
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", nil, &addresses) == 0, let first = addresses else { throw PuddleError("The unsubscribe host could not be resolved.") }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let item = cursor {
            let address = item.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address.ai_addr, address.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { throw PuddleError("Could not verify the unsubscribe destination.") }
            guard isPublic(String(cString: buffer)) else { throw PuddleError("Unsubscribe destinations on private or reserved networks are blocked.") }
            cursor = address.ai_next
        }
    }
    public static func isPublic(_ address: String) -> Bool {
        let address = address.lowercased()
        if address.contains(":") { return (address.hasPrefix("2") || address.hasPrefix("3")) && !address.hasPrefix("2001:db8:") }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1], c = parts[2]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)))) || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113))
    }
}
public struct NewsletterClient: Sendable {
    private let transport: any HTTPTransport
    private let validateHost: @Sendable (String) async throws -> Void
    public init(transport: any HTTPTransport = URLSessionTransport(), validateHost: @escaping @Sendable (String) async throws -> Void = { host in try await Task.detached { try PublicNewsletterHost.check(host) }.value }) { self.transport = transport; self.validateHost = validateHost }
    public func execute(_ action: ActionProposal) async throws -> ActionResult {
        guard action.status == .dispatching, action.authorizedDigest == action.digest, case .unsubscribe(let target) = action.payload else { throw PuddleError("Review an exact unsubscribe proposal first.") }
        try target.validate(); try await validateHost(target.url.host!); try Task.checkCancellation()
        var request = URLRequest(url: target.url, timeoutInterval: 30); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (data, response) = try await transport.sendBounded(request, maximumBytes: 64 * 1024, until: nil)
        guard (200..<300).contains(response.statusCode) else { throw PuddleError("The sender returned HTTP \(response.statusCode). No automatic retry was made; check the sender’s subscription settings.") }
        _ = data
        return ActionResult(id: action.id.uuidString)
    }
}
