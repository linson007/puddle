import Foundation

public enum TaskFrequency: String, Codable, CaseIterable, Sendable { case daily, weekly, monthly }
public struct TaskRepetition: Codable, Equatable, Sendable {
    public let frequency: TaskFrequency
    public let timezone: String
    public let day: Int
    public let hour: Int
    public let minute: Int
    public init(frequency: TaskFrequency, dueAt: Date, timezone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        self.frequency = frequency; self.timezone = timezone.identifier
        day = calendar.component(.day, from: dueAt); hour = calendar.component(.hour, from: dueAt); minute = calendar.component(.minute, from: dueAt)
    }
    public func next(after due: Date, now: Date) throws -> Date {
        guard let zone = TimeZone(identifier: timezone), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { throw PuddleError("Check the repeating commitment’s timezone and schedule.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let threshold = max(due, now)
        for offset in 1...5000 {
            let shifted: Date?
            if frequency == .monthly {
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: due))!
                let month = calendar.date(byAdding: .month, value: offset, to: start)!
                let lastDay = calendar.range(of: .day, in: .month, for: month)!.count
                shifted = calendar.date(byAdding: .day, value: min(day, lastDay) - 1, to: month)
            } else { shifted = calendar.date(byAdding: .day, value: offset * (frequency == .weekly ? 7 : 1), to: due) }
            if let shifted, let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted), candidate > threshold { return candidate }
        }
        throw PuddleError("This repeating date is too far in the past. Reschedule it before completing.")
    }
}
extension AppSnapshot {
    /// The parent retains the successor ID even if reopened or its successor is removed.
    public mutating func setTaskCompleted(_ id: UUID, completed: Bool, now: Date = Date()) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw PuddleError("This commitment was removed.") }
        let original = tasks[index]
        var successor: AssistantTask?
        if completed, !original.completed, original.nextOccurrenceID == nil, let repetition = original.repetition {
            guard let due = original.dueAt else { throw PuddleError("A repeating commitment needs a due date.") }
            var next = original; next.id = UUID(); next.createdAt = now
            next.dueAt = try repetition.next(after: due, now: now); next.completed = false
            next.notifiedAt = nil; next.focusDate = nil; next.nextOccurrenceID = nil
            successor = next
        }
        tasks[index].completed = completed
        if completed { tasks[index].focusDate = nil }
        if let successor { tasks[index].nextOccurrenceID = successor.id; tasks.append(successor) }
    }
}
