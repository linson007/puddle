import Foundation

public struct AssistantRoutine: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var prompt: String
    public var hour = 9
    public var minute = 0
    public var weekdays = [2, 3, 4, 5, 6]
    public var timezone = TimeZone.current.identifier
    public var enabled = false
    public var nextRunAt: Date?
    public init(title: String = "Morning brief", prompt: String = "Read my daily brief, identify priorities and conflicts, and suggest the next useful actions. Be explicit about stale or incomplete sources.") { self.title = title; self.prompt = prompt }
    public func validated() throws -> Self {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 4000,
              (0...23).contains(hour), (0...59).contains(minute), !weekdays.isEmpty,
              weekdays.allSatisfy({ (1...7).contains($0) }), Set(weekdays).count == weekdays.count,
              TimeZone(identifier: timezone) != nil else { throw PuddleError("Check the routine name, prompt, local time, timezone, and selected weekdays.") }
        return self
    }
    public func nextFire(after date: Date) -> Date? {
        guard let timezone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        for offset in 0..<9 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)), weekdays.contains(calendar.component(.weekday, from: day)),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward), candidate > date else { continue }
            return candidate
        }
        return nil
    }
}
public enum RoutineRunStatus: String, Codable, Sendable { case running, completed, failed, missed, interrupted }
public struct RoutineRun: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let routineID: UUID
    public let scheduledAt: Date
    public var finishedAt: Date?
    public var status: RoutineRunStatus
    public var result = ""
    public init(routineID: UUID, scheduledAt: Date, status: RoutineRunStatus) { self.routineID = routineID; self.scheduledAt = scheduledAt; self.status = status }
}
