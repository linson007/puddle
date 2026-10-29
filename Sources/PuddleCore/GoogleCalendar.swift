import Foundation

public struct CalendarPage: Codable, Sendable {
    public let events: [CalendarEvent]
    public let hasMore: Bool
    public init(events: [CalendarEvent], hasMore: Bool = false) { self.events = events; self.hasMore = hasMore }
}

public struct GoogleCalendarClient: Sendable {
    private let session: GoogleSession
    private let transport: any HTTPTransport
    public init(session: GoogleSession, transport: any HTTPTransport = URLSessionTransport()) {
        self.session = session; self.transport = RetryingTransport(base: transport)
    }
    public func upcoming(days: Int = 7, now: Date = Date()) async throws -> [CalendarEvent] {
        try await upcomingPage(days: days, now: now).events
    }
    public func upcomingPage(days: Int = 7, now: Date = Date()) async throws -> CalendarPage {
        let days = max(1, min(days, 14))
        var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        parts.queryItems = [URLQueryItem(name: "timeMin", value: now.ISO8601Format()),
                            URLQueryItem(name: "timeMax", value: (Calendar.current.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86400)).ISO8601Format()),
                            URLQueryItem(name: "singleEvents", value: "true"),
                            URLQueryItem(name: "orderBy", value: "startTime"),
                            URLQueryItem(name: "maxResults", value: "50")]
        var events: [CalendarEvent] = [], next: String?
        for _ in 0..<5 {
            try Task.checkCancellation()
            var pageParts = parts
            if let next { pageParts.queryItems?.append(URLQueryItem(name: "pageToken", value: next)) }
            var token = try await session.accessToken()
            var pageData: Data?
            for attempt in 0...1 {
                var request = URLRequest(url: pageParts.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await transport.send(request)
                if response.statusCode == 401, attempt == 0 { token = try await session.accessToken(rejected: token); continue }
                try checkHTTP(response, data: data, service: "Google Calendar")
                pageData = data; break
            }
            guard let data = pageData else { throw PuddleError("Reconnect Google Calendar in Connections.") }
            events += try Self.decode(data)
            struct Pagination: Decodable { let nextPageToken: String? }
            let tokenValue = try JSONDecoder().decode(Pagination.self, from: data).nextPageToken
            guard events.count < 50 else { return CalendarPage(events: Array(events.prefix(50)), hasMore: tokenValue != nil || events.count > 50) }
            guard let tokenValue else { return CalendarPage(events: events) }
            guard next != tokenValue else { throw PuddleError("Google Calendar returned a repeated page.") }
            next = tokenValue
        }
        return CalendarPage(events: events, hasMore: true)
    }
    public static func decode(_ data: Data) throws -> [CalendarEvent] {
        struct Page: Decodable {
            struct Event: Decodable {
                struct Time: Decodable { let dateTime: String?; let date: String? }
                struct Conference: Decodable {
                    struct Entry: Decodable { let entryPointType: String?; let uri: String? }
                    let entryPoints: [Entry]?
                }
                let id: String; let summary: String?; let start: Time?; let end: Time?
                let location: String?; let description: String?; let status: String?; let htmlLink: URL?
                let hangoutLink: String?; let conferenceData: Conference?
            }
            let items: [Event]?
        }
        return try JSONDecoder().decode(Page.self, from: data).items?.filter { $0.status != "cancelled" }.map { event in
            let conference = event.conferenceData?.entryPoints?.filter { $0.entryPointType == "video" }.compactMap(\.uri) ?? []
            let links = MeetingJoinLink.discover(in: conference + [event.hangoutLink ?? "", event.location ?? "", event.description ?? ""])
            return CalendarEvent(id: event.id, title: event.summary ?? "Untitled event", start: event.start?.dateTime ?? event.start?.date ?? "",
                          end: event.end?.dateTime ?? event.end?.date ?? "", location: event.location ?? "",
                          description: String(MailText.fromHTML(event.description ?? "").prefix(4000)),
                          sourceURL: event.htmlLink.flatMap { url in
                              let calendarHost = url.host == "calendar.google.com" || (url.host == "www.google.com" && url.path.hasPrefix("/calendar/"))
                              return url.scheme == "https" && calendarHost ? url : nil
                          }, meetingLinks: links)
        } ?? []
    }
}
