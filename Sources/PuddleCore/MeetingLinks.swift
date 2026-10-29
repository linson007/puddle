import Foundation

public enum MeetingProvider: String, Codable, Sendable {
    case googleMeet, zoom, teams, webex
    public var title: String {
        switch self { case .googleMeet: "Google Meet"; case .zoom: "Zoom"; case .teams: "Microsoft Teams"; case .webex: "Webex" }
    }
}

public struct MeetingJoinLink: Codable, Equatable, Sendable, Identifiable {
    public let url: URL
    public let provider: MeetingProvider
    public var id: String { url.absoluteString }

    public init(_ address: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.utf8.count <= 8192, !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else {
            throw PuddleError("Use an HTTPS meeting link from Google Meet, Zoom, Microsoft Teams, or Webex.")
        }
        let path = parts.path
        if host == "meet.google.com", path.range(of: #"^/(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/[^/]+?)/?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            provider = .googleMeet
        } else if (host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com")),
                  path.range(of: #"^/(?:[js]/[0-9]{6,15}|my/[A-Za-z0-9._-]+|wc/(?:join|j)/[0-9]{6,15})/?$"#, options: .regularExpression) != nil {
            provider = .zoom
        } else if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host),
                  path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") {
            provider = .teams
        } else if (host == "webex.com" || host.hasSuffix(".webex.com")),
                  path.hasPrefix("/meet/") || path.hasPrefix("/join/") || path.hasSuffix("/j.php") {
            provider = .webex
        } else { throw PuddleError("This is not a supported meeting join link. Open the original invitation to join this provider.") }
        parts.scheme = "https"; parts.host = host; parts.port = nil
        guard let url = parts.url else { throw PuddleError("The meeting link is invalid.") }
        self.url = url
    }

    enum CodingKeys: String, CodingKey { case url }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(URL.self, forKey: .url).absoluteString)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self); try values.encode(url, forKey: .url)
    }

    public static func discover(in texts: [String]) -> [Self] {
        var links: [Self] = [], seen = Set<String>()
        let pattern = #"https://[^\s<>\"']+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        for raw in texts.prefix(20) {
            let text = MailText.decodeEntities(String(raw.prefix(20_000)))
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(20) {
                guard let range = Range(match.range, in: text) else { continue }
                let candidate = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>"))
                if let link = try? Self(candidate), seen.insert(link.id).inserted { links.append(link) }
            }
        }
        return Array(links.prefix(5))
    }
}
