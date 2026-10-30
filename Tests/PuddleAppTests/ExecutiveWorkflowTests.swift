import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class ExecutiveDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ snapshot: AppSnapshot) throws {
        if failWrite { throw PuddleError("Full disk") }
        state = snapshot
    }
}
private final class ExecutiveSecrets: SecretStore, @unchecked Sendable {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
@MainActor private final class ExecutiveScheduler: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}
private actor BriefTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var completions = 0
    var delayCompletions = false
    let reminder: Bool
    init(reminder: Bool = false) { self.reminder = reminder }
    func delay() { delayCompletions = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        switch request.url!.path {
        case "/ready": body = #"{"status":"ready"}"#
        case "/v1/models": body = #"{"data":[{"id":"fixture","max_model_len":16384}]}"#
        default:
            if delayCompletions { try? await Task.sleep(for: .milliseconds(100)) }
            completions += 1
            if completions == 1, reminder {
                body = #"{"choices":[{"message":{"tool_calls":[{"id":"reminder","type":"function","function":{"name":"create_reminder","arguments":"{\"title\":\"Follow up\",\"due_at\":\"\"}"}}]},"finish_reason":"tool_calls"}]}"#
            } else {
                body = completions == 1
                    ? #"{"choices":[{"message":{"tool_calls":[{"id":"brief","type":"function","function":{"name":"read_executive_brief","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
                    : #"{"choices":[{"message":{"content":"Review the forecast first."},"finish_reason":"stop"}]}"#
            }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class ExecutiveWorkflowTests: XCTestCase {
    private func store(_ disk: ExecutiveDisk, transport: BriefTransport = BriefTransport()) -> PuddleStore {
        PuddleStore(cache: disk, secrets: ExecutiveSecrets(), transport: transport, reminderScheduler: ExecutiveScheduler())
    }
    func testProfileCommitmentAndDailyPriorityPersistAcrossRestart() async throws {
        let disk = ExecutiveDisk()
        let first = store(disk); await first.start()
        XCTAssertEqual(first.section, .today)
        var profile = ExecutiveProfile(); profile.name = "Mira"; profile.role = "COO"
        XCTAssertTrue(first.saveProfile(profile))
        var draft = TaskDraft(AssistantTask(title: "Get forecast")); draft.owner = "CFO"; draft.workflow = .waiting; draft.priority = .high
        XCTAssertTrue(first.saveCommitment(draft))
        let id = try XCTUnwrap(first.state.tasks.first?.id)
        first.setDailyPriority(id, enabled: true)
        let restarted = store(disk); await restarted.start()
        XCTAssertEqual(restarted.state.profile.name, "Mira"); XCTAssertEqual(restarted.state.tasks.first?.owner, "CFO")
        XCTAssertEqual(ExecutiveBrief(snapshot: restarted.state).priorities.map(\.id), [id])
        restarted.toggleTask(id)
        XCTAssertTrue(ExecutiveBrief(snapshot: restarted.state).priorities.isEmpty)
        restarted.toggleTask(id)
        XCTAssertNil(restarted.state.tasks.first?.focusDate)
    }

    func testFailedSaveReportsFailureAndDoesNotMutateSavedStateOrSource() async throws {
        let disk = ExecutiveDisk()
        let subject = store(disk); await subject.start()
        XCTAssertTrue(subject.addTask(title: "Saved", dueAt: nil))
        let id = subject.state.tasks[0].id
        var draft = TaskDraft(subject.state.tasks[0]); draft.title = "Draft still open"; draft.owner = "Mira"
        disk.failWrite = true
        XCTAssertFalse(subject.saveCommitment(draft, taskID: id))
        var profile = ExecutiveProfile(); profile.name = "Unsaved"
        XCTAssertFalse(subject.saveProfile(profile)); subject.setDailyPriority(id, enabled: true)
        XCTAssertEqual(subject.state.tasks[0].title, "Saved"); XCTAssertNil(subject.state.tasks[0].focusDate)
        XCTAssertTrue(subject.state.profile.name.isEmpty); XCTAssertNotNil(subject.errorMessage)
        disk.failWrite = false
        XCTAssertTrue(subject.saveCommitment(draft, taskID: id)); XCTAssertEqual(disk.state.tasks[0].title, "Draft still open")
    }

    func testDeletedCommitmentCannotBeResurrectedByStaleEditor() async {
        let disk = ExecutiveDisk()
        let first = store(disk); await first.start(); first.addTask(title: "Review", dueAt: nil)
        let task = first.state.tasks[0]; first.deleteTask(task.id)
        XCTAssertFalse(first.saveCommitment(TaskDraft(task), taskID: task.id)); XCTAssertTrue(first.state.tasks.isEmpty)
    }

    func testBriefingToolReadsSavedCommitmentsWithoutGoogleAndRecordsReceipt() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport()
        var profile = ExecutiveProfile(); profile.role = "CFO"; profile.objectives = "Forecast accuracy"
        disk.state.profile = profile; disk.state.tasks = [AssistantTask(title: "Review forecast", dueAt: .distantPast)]
        let subject = store(disk, transport: transport); await subject.start()
        XCTAssertTrue(subject.availableTools.contains(.briefing)); XCTAssertFalse(subject.calendarConnected)
        subject.ask("Give me a daily brief")
        for _ in 0..<200 where subject.isThinking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(subject.isThinking)
        let answer = try XCTUnwrap(subject.state.chat.last?.content)
        XCTAssertTrue(answer.contains("“Review forecast” — Active · Overdue"))
        XCTAssertTrue(answer.contains("Suggested next steps from saved work"))
        XCTAssertEqual(subject.state.chat.first(where: { $0.role == "user" })?.receipts?.first?.tool, AgentTool.briefing.rawValue)
        let calls = await transport.requests.filter { $0.url?.path == "/v1/chat/completions" }
        XCTAssertEqual(calls.count, 2)
        let second = String(decoding: try XCTUnwrap(calls.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(second.contains("Review forecast")); XCTAssertTrue(second.contains("Forecast accuracy"))
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.host == "www.googleapis.com" })
    }

    func testWorkspaceMergeIsAtomicRetainsActiveConversationAndCanRetryFailedSave() async throws {
        let disk = ExecutiveDisk(), subject = store(disk)
        await subject.start(); subject.addTask(title: "Current work", dueAt: nil)
        var backup = AppSnapshot(); backup.tasks = [AssistantTask(title: "Restored work", dueAt: .distantPast)]
        backup.chat = [ChatLine(role: "user", content: "Archived discussion")]
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(backup))
        let currentID = subject.state.currentConversationID
        disk.failWrite = true
        XCTAssertNil(subject.restoreWorkspaceBackup(preview)); XCTAssertEqual(subject.state.tasks.count, 1)
        disk.failWrite = false
        let report = try XCTUnwrap(subject.restoreWorkspaceBackup(preview))
        XCTAssertEqual(report.tasksAdded, 1); XCTAssertEqual(subject.state.currentConversationID, currentID)
        XCTAssertTrue(subject.state.chat.isEmpty); XCTAssertEqual(subject.state.conversations.count, 1)
        XCTAssertNotNil(subject.state.tasks.last?.notifiedAt)
        XCTAssertEqual(subject.restoreWorkspaceBackup(preview)?.tasksAdded, 0)
    }

    func testProfileSelectionAndContextPersistWhileAllWorkIsShared() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        subject.addTask(title: "Shared commitment", dueAt: nil)
        subject.saveMemory(title: "Working style", content: "Concrete next steps")
        try subject.commit { $0.chat = [ChatLine(role: "user", content: "Shared conversation")] }
        let currentID = subject.state.currentConversationID
        let custom = AssistantProfile(kind: .developer, title: "API developer", additionalGuidance: "Prefer Swift")
        XCTAssertTrue(subject.saveAssistantProfile(custom, isNew: true))
        XCTAssertEqual(subject.state.profileLibrary.activeID, custom.id)
        let personalID = subject.state.profileLibrary.profiles.first { $0.kind == .personal }!.id
        XCTAssertTrue(subject.switchAssistantProfile(personalID))
        XCTAssertTrue(subject.switchAssistantProfile(custom.id))
        let restarted = store(disk); await restarted.start()
        XCTAssertEqual(restarted.state.profileLibrary.activeID, custom.id)
        XCTAssertEqual(restarted.state.profileLibrary.active.additionalGuidance, "Prefer Swift")
        XCTAssertEqual(restarted.state.currentConversationID, currentID)
        XCTAssertEqual(restarted.state.chat.count, 1); XCTAssertEqual(restarted.state.tasks.count, 1); XCTAssertEqual(restarted.state.memories.count, 1)
    }

    func testDeveloperSidebarOnlyAppearsForDeveloperProfiles() async throws {
        let subject = store(ExecutiveDisk()); await subject.start()
        let custom = AssistantProfile(kind: .custom, title: "My profile")
        XCTAssertTrue(subject.saveAssistantProfile(custom, isNew: true))
        for profile in subject.state.profileLibrary.profiles {
            XCTAssertTrue(subject.switchAssistantProfile(profile.id))
            let sections = PuddleStore.SidebarGroup.allCases.flatMap { $0.sections(for: subject.state.profileLibrary.active.kind) }
            XCTAssertEqual(sections.contains(.developer), profile.kind == .developer, profile.title)
            XCTAssertEqual(Set(sections), Set(PuddleStore.Section.allCases.filter {
                $0 != .connections && ($0 != .developer || profile.kind == .developer)
            }))
            XCTAssertEqual(sections.count, Set(sections).count)
        }
    }

    func testLeavingDeveloperProfileReturnsToTodayAndKeepsOtherDestinations() async throws {
        let subject = store(ExecutiveDisk()); await subject.start()
        let personalID = subject.state.profileLibrary.activeID
        subject.chooseDeveloperProfile(); subject.section = .developer
        XCTAssertTrue(subject.switchAssistantProfile(personalID))
        XCTAssertEqual(subject.section, .today)

        for section in PuddleStore.Section.allCases where section != .developer {
            subject.section = section
            subject.chooseDeveloperProfile()
            XCTAssertEqual(subject.section, section)
            XCTAssertTrue(subject.switchAssistantProfile(personalID))
            XCTAssertEqual(subject.section, section)
        }
    }

    func testCreatingOrChangingActiveProfileLeavesDeveloperPageWhenUnavailable() async throws {
        let subject = store(ExecutiveDisk()); await subject.start()
        subject.chooseDeveloperProfile(); subject.section = .developer
        var developer = subject.state.profileLibrary.active
        developer.kind = .custom
        XCTAssertTrue(subject.saveAssistantProfile(developer, isNew: false))
        XCTAssertEqual(subject.section, .today)
        XCTAssertFalse(PuddleStore.SidebarGroup.workspace.sections(for: subject.state.profileLibrary.active.kind).contains(.developer))

        developer.kind = .developer
        XCTAssertTrue(subject.saveAssistantProfile(developer, isNew: false)); subject.section = .developer
        XCTAssertTrue(subject.saveAssistantProfile(AssistantProfile(title: "New role"), isNew: true))
        XCTAssertEqual(subject.section, .today)
    }

    func testFailedProfileSwitchRetainsDeveloperNavigationAndDraft() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        let personalID = subject.state.profileLibrary.activeID
        subject.chooseDeveloperProfile(); subject.section = .developer
        let developer = subject.state.profileLibrary.active
        _ = subject.createDevelopmentSession(kind: .debug)
        let session = try XCTUnwrap(subject.state.developmentSessions.first)
        subject.developerWorkspace.edit(session) { $0.findings = "Unsaved debugging evidence" }

        disk.failWrite = true
        XCTAssertFalse(subject.switchAssistantProfile(personalID))
        XCTAssertEqual(subject.section, .developer)
        XCTAssertEqual(subject.state.profileLibrary.activeID, developer.id)
        XCTAssertTrue(PuddleStore.SidebarGroup.workspace.sections(for: subject.state.profileLibrary.active.kind).contains(.developer))

        disk.failWrite = false
        XCTAssertTrue(subject.switchAssistantProfile(personalID))
        XCTAssertEqual(subject.section, .today)
        XCTAssertTrue(subject.switchAssistantProfile(developer.id))
        XCTAssertEqual(subject.developerWorkspace.draft(session).findings, "Unsaved debugging evidence")
    }

    func testFailedProfileMutationsRollBackSelectionAndKeepDraftForRetry() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        let original = subject.state.profileLibrary
        let developer = original.profiles.first { $0.kind == .developer }!
        var edit = developer; edit.additionalGuidance = "New guidance"
        disk.failWrite = true
        XCTAssertFalse(subject.switchAssistantProfile(developer.id))
        XCTAssertFalse(subject.saveAssistantProfile(edit, isNew: false))
        XCTAssertFalse(subject.deleteAssistantProfile(developer.id))
        XCTAssertFalse(subject.saveAssistantProfile(AssistantProfile(title: "Unsaved"), isNew: true))
        XCTAssertEqual(subject.state.profileLibrary, original)
        disk.failWrite = false
        XCTAssertTrue(subject.saveAssistantProfile(edit, isNew: false))
        XCTAssertEqual(subject.state.profileLibrary.profiles.first { $0.id == developer.id }?.additionalGuidance, "New guidance")
    }

    func testDuplicateAndDeleteOnlyChangeProfileConfiguration() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        subject.addTask(title: "Keep shared work", dueAt: nil)
        let original = subject.state.profileLibrary.active
        XCTAssertTrue(subject.duplicateAssistantProfile(original.id))
        let duplicate = subject.state.profileLibrary.active
        XCTAssertNotEqual(duplicate.id, original.id); XCTAssertEqual(duplicate.context, try original.context.validated())
        XCTAssertFalse(subject.deleteAssistantProfile(duplicate.id))
        XCTAssertTrue(subject.switchAssistantProfile(original.id)); XCTAssertTrue(subject.deleteAssistantProfile(duplicate.id))
        XCTAssertFalse(subject.saveAssistantProfile(duplicate, isNew: false))
        XCTAssertEqual(subject.state.tasks.count, 1); XCTAssertEqual(subject.state.profileLibrary.profiles.count, 2)
    }

    func testProfileSwitchRejectsLateReplyAndKeepsCurrentChat() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(), subject = store(disk, transport: transport)
        await subject.start(); await transport.delay()
        subject.ask("Help me plan today")
        for _ in 0..<200 {
            if await transport.requests.contains(where: { $0.url?.path == "/v1/chat/completions" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let currentID = subject.state.currentConversationID
        let developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        XCTAssertTrue(subject.switchAssistantProfile(developer.id))
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(subject.isThinking); XCTAssertTrue(subject.streamingReply.isEmpty)
        XCTAssertEqual(subject.state.currentConversationID, currentID)
        XCTAssertEqual(subject.state.chat.count, 1); XCTAssertEqual(subject.state.chat.first?.role, "user")
    }

    func testProfileSwitchCancelsPendingReminderApprovalWithoutCreatingTask() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(reminder: true), subject = store(disk, transport: transport)
        await subject.start(); subject.ask("Remind me to follow up")
        for _ in 0..<200 where subject.pendingApproval == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(subject.pendingApproval)
        let developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        XCTAssertTrue(subject.switchAssistantProfile(developer.id))
        await Task.yield()
        XCTAssertNil(subject.pendingApproval); XCTAssertFalse(subject.isThinking); XCTAssertTrue(subject.state.tasks.isEmpty)
    }

    func testSelectedProfileReachesModelAndIsRecordedOnReply() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(), subject = store(disk, transport: transport)
        await subject.start()
        var developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        developer.additionalGuidance = "Use Swift examples"
        XCTAssertTrue(subject.saveAssistantProfile(developer, isNew: false)); XCTAssertTrue(subject.switchAssistantProfile(developer.id))
        subject.ask("Give me a daily brief")
        for _ in 0..<200 where subject.isThinking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(subject.state.chat.last?.profileName, "Developer")
        let requests = await transport.requests.filter { $0.url?.path == "/v1/chat/completions" }
        let requestText = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(requestText.contains("Use Swift examples")); XCTAssertTrue(requestText.contains("developer's assistant"))
        XCTAssertEqual(try disk.load().chat.last?.profileName, "Developer")
    }
}
