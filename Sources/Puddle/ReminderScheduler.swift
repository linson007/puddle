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
    func clearDeliveredReminders() async
}

extension NotificationScheduling { func clearDeliveredReminders() async {} }

@MainActor final class SystemNotifications: NotificationScheduling {
    func pendingIdentifiers() async -> [String] {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return [] }
        return await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }
    func removePending(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: UNNotificationRequest) async throws { try await UNUserNotificationCenter.current().add(request) }
    func clearDeliveredReminders() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix("puddle.reminder.") }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Serialize reconciliation so a slow earlier request cannot restore a deleted reminder.
@MainActor final class ReminderScheduler: ReminderScheduling {
    /// macOS keeps a bounded number of pending local notifications. Schedule the
    /// nearest due commitments and roll the window forward as they fire rather
    /// than silently losing reminders in a long-lived workspace.
    static let maximumScheduledReminders = 60
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
            guard enabled else { await center.clearDeliveredReminders(); return }
            let upcoming = tasks
                .filter { !$0.completed && $0.notifiedAt == nil && ($0.dueAt ?? .distantPast) > Date() }
                .sorted { ($0.dueAt ?? .distantFuture) == ($1.dueAt ?? .distantFuture) ? $0.id.uuidString < $1.id.uuidString : ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
                .prefix(Self.maximumScheduledReminders)
            for task in upcoming {
                guard let due = task.dueAt else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Puddle reminder"; content.body = "A commitment is due. Open Puddle to review."; content.sound = .default
                content.userInfo = ["taskID": task.id.uuidString]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
                try await center.add(UNNotificationRequest(identifier: "puddle.reminder.\(task.id.uuidString)", content: content, trigger: trigger))
            }
        }
        work = task
        try await task.value
    }
}

extension PuddleStore {
    func clearReminderNotifications() async {
        do { try await reminderScheduler.reconcile(tasks: [], enabled: false) }
        catch { fail(PuddleError("Puddle could not clear reminder notifications. Check Notification Center.")) }
    }
}
