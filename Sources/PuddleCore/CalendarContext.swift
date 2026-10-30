import Foundation

public enum CalendarContext {
    public static func localTime(_ raw: String, timezone: TimeZone = .current) -> String {
        if raw.count == 10 { return raw + " (all day)" }
        guard let date = AssistantDates.parse(raw) else { return raw.isEmpty ? "unknown" : raw }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timezone
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
    public static func encode(_ page: CalendarPage, timezone: TimeZone = .current) throws -> String {
        let data = try JSONEncoder().encode(page)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var events = object["events"] as? [[String: Any]] ?? []
        for index in events.indices {
            events[index]["local_start"] = localTime(events[index]["start"] as? String ?? "", timezone: timezone)
            events[index]["local_end"] = localTime(events[index]["end"] as? String ?? "", timezone: timezone)
        }
        object["events"] = events; object["timezone"] = timezone.identifier
        object["time_display_rule"] = "Use local_start/local_end when displaying times. Raw start/end may use UTC; never relabel a UTC clock time as local."
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
