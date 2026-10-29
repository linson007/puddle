import Foundation
import PuddleCore
import UserNotifications

@MainActor protocol ReminderScheduling: AnyObject {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws
}

@MainActor protocol NotificationScheduling: AnyObject {
    func pendingIdentifiers() async -> [String]
    func removePending(_ identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor final class SystemNotifications: NotificationScheduling {
    func pendingIdentifiers() async -> [String] { await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier) }
    func removePending(_ identifiers: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers) }
    func add(_ request: UNNotificationRequest) async throws { try await UNUserNotificationCenter.current().add(request) }
}

/// Serialize reconciliation so a slow earlier request cannot restore a deleted reminder.
@MainActor final class ReminderScheduler: ReminderScheduling {
    private var work: Task<Void, Error>?
    private let center: any NotificationScheduling
    init(center: (any NotificationScheduling)? = nil) { self.center = center ?? SystemNotifications() }
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {
        let previous = work
        let center = self.center
        let task = Task {
            _ = try? await previous?.value
            let owned = await center.pendingIdentifiers().filter { $0.hasPrefix("puddle.reminder.") }
            center.removePending(owned)
            guard enabled else { return }
            for task in tasks where !task.completed && task.notifiedAt == nil {
                guard let due = task.dueAt, due > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Puddle reminder"; content.body = task.title; content.sound = .default
                content.userInfo = ["taskID": task.id.uuidString]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
                try await center.add(UNNotificationRequest(identifier: "puddle.reminder.\(task.id.uuidString)", content: content, trigger: trigger))
            }
        }
        work = task
        try await task.value
    }
}
