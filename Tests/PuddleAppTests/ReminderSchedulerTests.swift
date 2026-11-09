import Foundation
import XCTest
import UserNotifications
import PuddleCore
@testable import Puddle

@MainActor private final class FakeNotifications: NotificationScheduling {
    var requests: [String: UNNotificationRequest] = [:]
    var delivered = Set<String>()
    func pendingIdentifiers() async -> [String] { Array(requests.keys) }
    func removePending(_ identifiers: [String]) { for id in identifiers { requests[id] = nil } }
    func add(_ request: UNNotificationRequest) async throws { requests[request.identifier] = request }
    func clearDeliveredReminders() async { delivered = delivered.filter { !$0.hasPrefix("puddle.reminder.") } }
}

@MainActor final class ReminderSchedulerTests: XCTestCase {
    func testSchedulingUsesStableIDsAndReconcilesEditsCompletionAndDisabling() async throws {
        let center = FakeNotifications(), scheduler = ReminderScheduler(center: center)
        var task = AssistantTask(title: "Original", dueAt: Date().addingTimeInterval(600))
        let identifier = "puddle.reminder.\(task.id.uuidString)"
        center.delivered = [identifier, "unrelated"]
        try await scheduler.reconcile(tasks: [task], enabled: true)
        XCTAssertEqual(center.requests[identifier]?.content.body, "A commitment is due. Open Puddle to review.")
        XCTAssertTrue(center.requests[identifier]?.trigger is UNTimeIntervalNotificationTrigger)
        task.title = "Changed"
        try await scheduler.reconcile(tasks: [task], enabled: true)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests[identifier]?.content.body, "A commitment is due. Open Puddle to review.")
        task.completed = true
        try await scheduler.reconcile(tasks: [task], enabled: true)
        XCTAssertTrue(center.requests.isEmpty)
        task.completed = false
        try await scheduler.reconcile(tasks: [task], enabled: true)
        try await scheduler.reconcile(tasks: [task], enabled: false)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.delivered, ["unrelated"])
    }

    func testReconciliationDoesNotRescheduleOverdueOrAlreadyNotifiedTasks() async throws {
        let center = FakeNotifications(), scheduler = ReminderScheduler(center: center)
        let unrelated = UNNotificationRequest(identifier: "other.notification", content: UNMutableNotificationContent(), trigger: nil)
        center.requests[unrelated.identifier] = unrelated
        var notified = AssistantTask(title: "Delivered", dueAt: Date().addingTimeInterval(500)); notified.notifiedAt = Date()
        try await scheduler.reconcile(tasks: [AssistantTask(title: "Overdue", dueAt: .distantPast), notified], enabled: true)
        XCTAssertEqual(Array(center.requests.keys), ["other.notification"])
    }
}
