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
    let gate = AsyncTestGate()
    let reminder: Bool
    init(reminder: Bool = false) { self.reminder = reminder }
    func delay() { delayCompletions = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        switch request.url!.path {
        case "/v1/models": body = #"{"data":[{"id":"fixture","max_model_len":16384}]}"#
        default:
            if delayCompletions { await gate.pause() }
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
        let result1 = await first.saveProfile(profile)
        XCTAssertTrue(result1)
        var draft = TaskDraft(AssistantTask(title: "Get forecast")); draft.owner = "CFO"; draft.workflow = .waiting; draft.priority = .high
        let result2 = await first.saveCommitment(draft)
        XCTAssertTrue(result2)
        let id = try XCTUnwrap(first.state.tasks.first?.id)
        await first.setDailyPriority(id, enabled: true)
        let restarted = store(disk); await restarted.start()
        XCTAssertEqual(restarted.state.profile.name, "Mira"); XCTAssertEqual(restarted.state.tasks.first?.owner, "CFO")
        XCTAssertEqual(ExecutiveBrief(snapshot: restarted.state).priorities.map(\.id), [id])
        await restarted.toggleTask(id)
        XCTAssertTrue(ExecutiveBrief(snapshot: restarted.state).priorities.isEmpty)
        await restarted.toggleTask(id)
        XCTAssertNil(restarted.state.tasks.first?.focusDate)
    }

    func testFailedSaveReportsFailureAndDoesNotMutateSavedStateOrSource() async throws {
        let disk = ExecutiveDisk()
        let subject = store(disk); await subject.start()
        let result3 = await subject.addTask(title: "Saved", dueAt: nil)
        XCTAssertTrue(result3)
        let id = subject.state.tasks[0].id
        var draft = TaskDraft(subject.state.tasks[0]); draft.title = "Draft still open"; draft.owner = "Mira"
        disk.failWrite = true
        let result4 = await subject.saveCommitment(draft, taskID: id)
        XCTAssertFalse(result4)
        var profile = ExecutiveProfile(); profile.name = "Unsaved"
        let result5 = await subject.saveProfile(profile)
        XCTAssertFalse(result5); await subject.setDailyPriority(id, enabled: true)
        XCTAssertEqual(subject.state.tasks[0].title, "Saved"); XCTAssertNil(subject.state.tasks[0].focusDate)
        XCTAssertTrue(subject.state.profile.name.isEmpty); XCTAssertNotNil(subject.errorMessage)
        disk.failWrite = false
        let result6 = await subject.saveCommitment(draft, taskID: id)
        XCTAssertTrue(result6); XCTAssertEqual(disk.state.tasks[0].title, "Draft still open")
    }

    func testDeletedCommitmentCannotBeResurrectedByStaleEditor() async {
        let disk = ExecutiveDisk()
        let first = store(disk); await first.start(); await first.addTask(title: "Review", dueAt: nil)
        let task = first.state.tasks[0]; await first.deleteTask(task.id)
        let result7 = await first.saveCommitment(TaskDraft(task), taskID: task.id)
        XCTAssertFalse(result7); XCTAssertTrue(first.state.tasks.isEmpty)
    }

    func testBriefingToolReadsSavedCommitmentsWithoutGoogleAndRecordsReceipt() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport()
        var profile = ExecutiveProfile(); profile.role = "CFO"; profile.objectives = "Forecast accuracy"
        disk.state.profile = profile; disk.state.tasks = [AssistantTask(title: "Review forecast", dueAt: .distantPast)]
        let subject = store(disk, transport: transport); await subject.start()
        XCTAssertTrue(subject.availableTools.contains(.briefing)); XCTAssertFalse(subject.calendarConnected)
        await subject.ask("Give me a daily brief")
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
        await subject.start(); await subject.addTask(title: "Current work", dueAt: nil)
        var backup = AppSnapshot(); backup.tasks = [AssistantTask(title: "Restored work", dueAt: .distantPast)]
        backup.chat = [ChatLine(role: "user", content: "Archived discussion")]
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(backup))
        let currentID = subject.state.currentConversationID
        disk.failWrite = true
        let result8 = await subject.restoreWorkspaceBackup(preview)
        XCTAssertNil(result8); XCTAssertEqual(subject.state.tasks.count, 1)
        disk.failWrite = false
        let result9 = await subject.restoreWorkspaceBackup(preview);         let report = try XCTUnwrap(result9)
        XCTAssertEqual(report.tasksAdded, 1); XCTAssertEqual(subject.state.currentConversationID, currentID)
        XCTAssertTrue(subject.state.chat.isEmpty); XCTAssertEqual(subject.state.conversations.count, 1)
        XCTAssertNotNil(subject.state.tasks.last?.notifiedAt)
        let result10 = await subject.restoreWorkspaceBackup(preview)?.tasksAdded
        XCTAssertEqual(result10, 0)
    }

    func testProfileSelectionAndContextPersistWhileAllWorkIsShared() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        await subject.addTask(title: "Shared commitment", dueAt: nil)
        await subject.saveMemory(title: "Working style", content: "Concrete next steps")
        try await subject.commit { $0.chat = [ChatLine(role: "user", content: "Shared conversation")] }
        let currentID = subject.state.currentConversationID
        let custom = AssistantProfile(kind: .developer, title: "API developer", additionalGuidance: "Prefer Swift")
        let result11 = await subject.saveAssistantProfile(custom, isNew: true)
        XCTAssertTrue(result11)
        XCTAssertEqual(subject.state.profileLibrary.activeID, custom.id)
        let personalID = subject.state.profileLibrary.profiles.first { $0.kind == .personal }!.id
        let result12 = await subject.switchAssistantProfile(personalID)
        XCTAssertTrue(result12)
        let result13 = await subject.switchAssistantProfile(custom.id)
        XCTAssertTrue(result13)
        let restarted = store(disk); await restarted.start()
        XCTAssertEqual(restarted.state.profileLibrary.activeID, custom.id)
        XCTAssertEqual(restarted.state.profileLibrary.active.additionalGuidance, "Prefer Swift")
        XCTAssertEqual(restarted.state.currentConversationID, currentID)
        XCTAssertEqual(restarted.state.chat.count, 1); XCTAssertEqual(restarted.state.tasks.count, 1); XCTAssertEqual(restarted.state.memories.count, 1)
    }

    func testDeveloperSidebarOnlyAppearsForDeveloperProfiles() async throws {
        let subject = store(ExecutiveDisk()); await subject.start()
        let custom = AssistantProfile(kind: .custom, title: "My profile")
        let result14 = await subject.saveAssistantProfile(custom, isNew: true)
        XCTAssertTrue(result14)
        for profile in subject.state.profileLibrary.profiles {
            let result15 = await subject.switchAssistantProfile(profile.id)
            XCTAssertTrue(result15)
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
        await subject.chooseDeveloperProfile(); subject.section = .developer
        let result16 = await subject.switchAssistantProfile(personalID)
        XCTAssertTrue(result16)
        XCTAssertEqual(subject.section, .today)

        for section in PuddleStore.Section.allCases where section != .developer {
            subject.section = section
            await subject.chooseDeveloperProfile()
            XCTAssertEqual(subject.section, section)
            let result17 = await subject.switchAssistantProfile(personalID)
            XCTAssertTrue(result17)
            XCTAssertEqual(subject.section, section)
        }
    }

    func testCreatingOrChangingActiveProfileLeavesDeveloperPageWhenUnavailable() async throws {
        let subject = store(ExecutiveDisk()); await subject.start()
        await subject.chooseDeveloperProfile(); subject.section = .developer
        var developer = subject.state.profileLibrary.active
        developer.kind = .custom
        let result18 = await subject.saveAssistantProfile(developer, isNew: false)
        XCTAssertTrue(result18)
        XCTAssertEqual(subject.section, .today)
        XCTAssertFalse(PuddleStore.SidebarGroup.workspace.sections(for: subject.state.profileLibrary.active.kind).contains(.developer))

        developer.kind = .developer
        let result19 = await subject.saveAssistantProfile(developer, isNew: false)
        XCTAssertTrue(result19); subject.section = .developer
        let result20 = await subject.saveAssistantProfile(AssistantProfile(title: "New role"), isNew: true)
        XCTAssertTrue(result20)
        XCTAssertEqual(subject.section, .today)
    }

    func testFailedProfileSwitchRetainsDeveloperNavigationAndDraft() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        let personalID = subject.state.profileLibrary.activeID
        await subject.chooseDeveloperProfile(); subject.section = .developer
        let developer = subject.state.profileLibrary.active
        _ = await subject.createDevelopmentSession(kind: .debug)
        let session = try XCTUnwrap(subject.state.developmentSessions.first)
        subject.developerWorkspace.edit(session) { $0.findings = "Unsaved debugging evidence" }

        disk.failWrite = true
        let result21 = await subject.switchAssistantProfile(personalID)
        XCTAssertFalse(result21)
        XCTAssertEqual(subject.section, .developer)
        XCTAssertEqual(subject.state.profileLibrary.activeID, developer.id)
        XCTAssertTrue(PuddleStore.SidebarGroup.workspace.sections(for: subject.state.profileLibrary.active.kind).contains(.developer))

        disk.failWrite = false
        let result22 = await subject.switchAssistantProfile(personalID)
        XCTAssertTrue(result22)
        XCTAssertEqual(subject.section, .today)
        let result23 = await subject.switchAssistantProfile(developer.id)
        XCTAssertTrue(result23)
        XCTAssertEqual(subject.developerWorkspace.draft(session).findings, "Unsaved debugging evidence")
    }

    func testFailedProfileMutationsRollBackSelectionAndKeepDraftForRetry() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        let original = subject.state.profileLibrary
        let developer = original.profiles.first { $0.kind == .developer }!
        var edit = developer; edit.additionalGuidance = "New guidance"
        disk.failWrite = true
        let result24 = await subject.switchAssistantProfile(developer.id)
        XCTAssertFalse(result24)
        let result25 = await subject.saveAssistantProfile(edit, isNew: false)
        XCTAssertFalse(result25)
        let result26 = await subject.deleteAssistantProfile(developer.id)
        XCTAssertFalse(result26)
        let result27 = await subject.saveAssistantProfile(AssistantProfile(title: "Unsaved"), isNew: true)
        XCTAssertFalse(result27)
        XCTAssertEqual(subject.state.profileLibrary, original)
        disk.failWrite = false
        let result28 = await subject.saveAssistantProfile(edit, isNew: false)
        XCTAssertTrue(result28)
        XCTAssertEqual(subject.state.profileLibrary.profiles.first { $0.id == developer.id }?.additionalGuidance, "New guidance")
    }

    func testDuplicateAndDeleteOnlyChangeProfileConfiguration() async throws {
        let disk = ExecutiveDisk(), subject = store(disk); await subject.start()
        await subject.addTask(title: "Keep shared work", dueAt: nil)
        let original = subject.state.profileLibrary.active
        let result29 = await subject.duplicateAssistantProfile(original.id)
        XCTAssertTrue(result29)
        let duplicate = subject.state.profileLibrary.active
        XCTAssertNotEqual(duplicate.id, original.id); XCTAssertEqual(duplicate.context, try original.context.validated())
        let result30 = await subject.deleteAssistantProfile(duplicate.id)
        XCTAssertFalse(result30)
        let result31 = await subject.switchAssistantProfile(original.id)
        XCTAssertTrue(result31); let result32 = await subject.deleteAssistantProfile(duplicate.id)
        XCTAssertTrue(result32)
        let result33 = await subject.saveAssistantProfile(duplicate, isNew: false)
        XCTAssertFalse(result33)
        XCTAssertEqual(subject.state.tasks.count, 1); XCTAssertEqual(subject.state.profileLibrary.profiles.count, 2)
    }

    func testProfileSwitchRejectsLateReplyAndKeepsCurrentChat() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(), subject = store(disk, transport: transport)
        await subject.start(); await transport.delay()
        await subject.ask("Help me plan today")
        await fulfillment(of: [transport.gate.entered], timeout: 5)
        let turn = subject.aiTask
        let currentID = subject.state.currentConversationID
        let developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        let result34 = await subject.switchAssistantProfile(developer.id)
        XCTAssertTrue(result34)
        await transport.gate.release(); await turn?.value
        XCTAssertFalse(subject.isThinking); XCTAssertTrue(subject.streamingReply.isEmpty)
        XCTAssertEqual(subject.state.currentConversationID, currentID)
        XCTAssertEqual(subject.state.chat.count, 1); XCTAssertEqual(subject.state.chat.first?.role, "user")
    }

    func testProfileSwitchCancelsPendingReminderApprovalWithoutCreatingTask() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(reminder: true), subject = store(disk, transport: transport)
        await subject.start(); await subject.ask("Remind me to follow up")
        for _ in 0..<200 where subject.pendingApproval == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(subject.pendingApproval)
        let developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        let result35 = await subject.switchAssistantProfile(developer.id)
        XCTAssertTrue(result35)
        await Task.yield()
        XCTAssertNil(subject.pendingApproval); XCTAssertFalse(subject.isThinking); XCTAssertTrue(subject.state.tasks.isEmpty)
    }

    func testSelectedProfileReachesModelAndIsRecordedOnReply() async throws {
        let disk = ExecutiveDisk(), transport = BriefTransport(), subject = store(disk, transport: transport)
        await subject.start()
        var developer = subject.state.profileLibrary.profiles.first { $0.kind == .developer }!
        developer.additionalGuidance = "Use Swift examples"
        let result36 = await subject.saveAssistantProfile(developer, isNew: false)
        XCTAssertTrue(result36); let result37 = await subject.switchAssistantProfile(developer.id)
        XCTAssertTrue(result37)
        await subject.ask("Give me a daily brief")
        for _ in 0..<200 where subject.isThinking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(subject.state.chat.last?.profileName, "Developer")
        let requests = await transport.requests.filter { $0.url?.path == "/v1/chat/completions" }
        let requestText = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(requestText.contains("Use Swift examples")); XCTAssertTrue(requestText.contains("developer's assistant"))
        XCTAssertEqual(try disk.load().chat.last?.profileName, "Developer")
    }
}
