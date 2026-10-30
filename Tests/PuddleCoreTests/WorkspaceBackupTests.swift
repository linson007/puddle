import Foundation
import XCTest
@testable import PuddleCore

final class WorkspaceBackupTests: XCTestCase {
    func testPortableBackupIncludesSavedWorkAndExcludesConnectedAccountAndModelConfiguration() throws {
        var state = AppSnapshot(); state.profile.name = "Mira"
        state.messages = [MailMessage(id: "mail", subject: "PRIVATE MAIL", sender: "Sender", body: "UNEXPORTED MAIL CACHE")]
        state.calendarEvents = [CalendarEvent(id: "private", title: "UNEXPORTED EVENT CACHE", start: "2026-10-29")]
        state.settings.splashAddress = "http://localhost:9999"; state.account = "EXCLUDED ACCOUNT"
        state.remember(title: "Preference", content: "Concise replies")
        state.tasks = [AssistantTask(title: "Review plan")]; state.meetings = [MeetingNote(title: "Leadership")]
        state.chat = [ChatLine(role: "user", content: "Saved work")]
        let data = try WorkspaceBackup.encode(state)
        let outer = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let compressed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(outer["payload"] as? String)))
        let payload = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("UNEXPORTED")); XCTAssertFalse(text.contains("EXCLUDED ACCOUNT")); XCTAssertFalse(text.contains("localhost:9999"))
        let preview = try WorkspaceBackup.inspect(data)
        XCTAssertEqual(preview.memoriesCount, 1); XCTAssertEqual(preview.tasksCount, 1)
        XCTAssertEqual(preview.meetingsCount, 1); XCTAssertEqual(preview.conversationsCount, 1)
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot()).0
        XCTAssertEqual(restored.profile.name, "Mira"); XCTAssertEqual(restored.conversations[0].lines, state.chat)
        XCTAssertTrue(restored.chat.isEmpty); XCTAssertTrue(restored.messages.isEmpty)
    }

    func testMergePreservesCurrentEditsCurrentProfileConnectionsAndPreferences() throws {
        var current = AppSnapshot(); current.profile.name = "Current"; current.profile.configured = true
        current.settings.notifications = true; current.account = "Current account"; current.assistantInstructions = "My current preferences"
        current.tasks = [AssistantTask(title: "Current task")]
        current.remember(title: "Style", content: "Current style")
        current.chat = [ChatLine(role: "user", content: "Active discussion")]
        var backup = current; backup.tasks[0].title = "Old task"; backup.memories[0].content = "Old style"
        backup.profile.name = "Old"; backup.assistantInstructions = "Old preferences"
        backup.memories.append(MemoryNote(title: "STYLE!", content: "Duplicate title"))
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(backup))
        let (merged, report) = WorkspaceBackup.merging(preview, into: current)
        XCTAssertEqual(merged.tasks[0].title, "Current task"); XCTAssertEqual(merged.memories[0].content, "Current style")
        XCTAssertEqual(merged.memories.count, 1); XCTAssertEqual(merged.profile.name, "Current")
        XCTAssertEqual(merged.account, current.account); XCTAssertEqual(merged.assistantInstructions, current.assistantInstructions)
        XCTAssertTrue(merged.settings.notifications); XCTAssertEqual(merged.chat, current.chat); XCTAssertTrue(merged.conversations.isEmpty)
        XCTAssertEqual(report.tasksAdded, 0); XCTAssertEqual(report.skipped, 4)
    }

    func testImportIsIdempotentKeepsTaskProvenanceAndDoesNotReplayOldReminders() throws {
        var source = AppSnapshot()
        var old = AssistantTask(title: "Overdue", dueAt: .distantPast); old.focusDate = Date()
        old.meetingSource = MeetingTaskSource(meetingID: UUID(), actionID: UUID(), quote: "Explicit action")
        source.tasks = [old, AssistantTask(title: "Future", dueAt: .distantFuture)]
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(source))
        let (first, initial) = WorkspaceBackup.merging(preview, into: AppSnapshot())
        XCTAssertEqual(initial.tasksAdded, 2); XCTAssertNil(first.tasks[0].focusDate)
        XCTAssertNotNil(first.tasks[0].notifiedAt); XCTAssertNil(first.tasks[1].notifiedAt)
        XCTAssertEqual(first.tasks[0].meetingSource, old.meetingSource)
        var mutable = first; XCTAssertTrue(mutable.dueReminders().isEmpty)
        let (second, repeated) = WorkspaceBackup.merging(preview, into: first)
        XCTAssertEqual(second.tasks, first.tasks); XCTAssertEqual(repeated.tasksAdded, 0)
    }

    func testIntegrityMismatchUnsupportedFormatAndMalformedDataCannotBeLoaded() throws {
        let valid = try WorkspaceBackup.encode(AppSnapshot())
        var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        object["sha256"] = "broken"
        XCTAssertThrowsError(try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: object)))
        object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]; object["version"] = 999
        XCTAssertThrowsError(try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try WorkspaceBackup.inspect(Data("{invalid".utf8)))
    }

    func testDuplicateIDsAndInvalidWaitingTaskAreRejectedBeforeMerge() throws {
        var source = AppSnapshot(); let task = AssistantTask(title: "Repeated")
        source.tasks = [task, task]
        XCTAssertThrowsError(try WorkspaceBackup.inspect(WorkspaceBackup.encode(source)))
        var invalid = task; invalid.workflow = .waiting
        source.tasks = [invalid]
        XCTAssertThrowsError(try WorkspaceBackup.inspect(WorkspaceBackup.encode(source)))
    }

    func testWorkContextAndProjectLinksRoundTripWithoutRestoringFolderGrants() throws {
        var source = AppSnapshot(), project = WorkProject(), person = PersonContext(), decision = WorkDecision()
        project.title = "Launch"; person.name = "Alex"; person.email = "alex@example.com"; person.isVIP = true
        decision.title = "Choose a launch date"; decision.projectID = project.id
        var task = AssistantTask(title: "Prepare launch"); task.projectID = project.id
        source.workProjects = [project]; source.people = [person]; source.workDecisions = [decision]; source.tasks = [task]
        let backup = try WorkspaceBackup.inspect(WorkspaceBackup.encode(source))
        let (restored, report) = WorkspaceBackup.merging(backup, into: AppSnapshot())
        XCTAssertEqual(report.projectsAdded, 1); XCTAssertEqual(report.peopleAdded, 1); XCTAssertEqual(report.decisionsAdded, 1)
        XCTAssertEqual(restored.tasks.first?.projectID, project.id); XCTAssertEqual(restored.workDecisions.first?.projectID, project.id)
        XCTAssertTrue(restored.people.first?.isVIP == true); XCTAssertTrue(restored.knowledgeSources.isEmpty)
        let again = WorkspaceBackup.merging(backup, into: restored).1
        XCTAssertEqual(again.projectsAdded + again.peopleAdded + again.decisionsAdded, 0)
    }

    func testBackupFileUsesOwnerOnlyPermissionsAndCanBeRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-backup-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try WorkspaceBackup.encode(AppSnapshot())
        try WorkspaceBackup.write(data, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try WorkspaceBackup.read(url).tasksCount, 0)
    }
}
