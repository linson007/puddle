import Foundation

public enum TaskFilter: String, CaseIterable, Sendable {
    case open = "Open", dueToday = "Due today", overdue = "Overdue", waiting = "Waiting on", completed = "Completed"

    public var emptyTitle: String {
        switch self {
        case .open: "No open tasks"
        case .dueToday: "No tasks due today"
        case .overdue: "No overdue tasks"
        case .waiting: "Not waiting on anyone"
        case .completed: "No completed tasks"
        }
    }

    public var emptyMessage: String {
        switch self {
        case .open: "Capture your next action above. A small step is a good start."
        case .dueToday: "Nothing else is due today. Earlier deadlines are in Overdue."
        case .overdue: "You're caught up. No open tasks have passed their deadline."
        case .waiting: "Give a task an owner and choose Waiting on someone to track a follow-up."
        case .completed: "Completed tasks will appear here."
        }
    }

    public func matches(_ task: AssistantTask, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if self == .completed { return task.completed }
        guard !task.completed else { return false }
        switch self {
        case .open: return true
        case .dueToday: return task.dueAt.map { $0 >= now && calendar.isDate($0, inSameDayAs: now) } ?? false
        case .overdue: return task.dueAt.map { $0 < now } ?? false
        case .waiting: return task.workflow == .waiting
        case .completed: return false
        }
    }
}
