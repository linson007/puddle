import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class BrowserDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ snapshot: AppSnapshot) throws {
        if failWrite { throw PuddleError("Fixture disk full") }
        state = snapshot
    }
}
private struct BrowserSecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
@MainActor private final class BrowserReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}
private actor BrowserController: CuaBrowserControlling {
    var actions = 0
    var disconnected = false
    var delay = false
    var failAfterDispatch = false
    func configure(delay: Bool = false, failAfterDispatch: Bool = false) { self.delay = delay; self.failAfterDispatch = failAfterDispatch }
    func connect(executable: URL) async throws -> CuaBrowserPage { page() }
    func observe(tabID: String, query: String) async throws -> CuaBrowserPage { page() }
    func act(_ action: CuaBrowserAction) async throws -> CuaBrowserPage {
        actions += 1
        if delay { try? await Task.sleep(for: .milliseconds(100)) }
        if failAfterDispatch { throw PuddleError("Action may have happened; read before retrying") }
        return page()
    }
    func disconnect() async { disconnected = true }
    private func page() -> CuaBrowserPage { CuaBrowserPage(text: #"{"outline":"Fixture browser page","refs":[{"ref":"p1:field","name":"Test note","actions":["type"]}]}"#, summary: "Fixture browser page", processID: 1234, elements: ["p1:field": "Test note", "p1:button": "Button"], actions: ["p1:field": ["type"], "p1:button": ["click"]]) }
}
private actor BrowserModel: HTTPTransport {
    var requests: [URLRequest] = []
    var typeRef: String?
    var clickRef: String?
    var serializedArguments = false
    func requestTyping(ref: String) { typeRef = ref }
    func requestClick(ref: String, serialized: Bool = false) { clickRef = ref; serializedArguments = serialized }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: [String: Any]
        switch request.url!.path {
        case "/ready": body = ["status": "ready"]
        case "/v1/models": body = ["data": [["id": "fixture", "max_model_len": 32768]]]
        default:
            let data = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = data["messages"] as! [[String: Any]]
            if messages.last?["role"] as? String == "tool" {
                body = ["choices": [["message": ["content": "Observed fixture browser page."], "finish_reason": "stop"]]]
            } else {
                let tools = data["tools"] as? [[String: Any]] ?? []
                let canNavigate = tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "navigate_browser" }
                let name = canNavigate ? (clickRef != nil ? "click_browser_element" : typeRef == nil ? "navigate_browser" : "type_in_browser") : "read_browser_page"
                let args: [String: Any] = canNavigate ? (clickRef.map { ["ref": $0] } ?? typeRef.map { ["ref": $0, "text": "local test", "replace": true] } ?? ["url": "https://example.test/"]) : ["tab_id": "", "query": ""]
                let arguments: Any = serializedArguments ? String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self) : args
                body = ["choices": [["message": ["tool_calls": [["id": canNavigate ? "browser-action" : "browser-read", "type": "function", "function": ["name": name, "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
            }
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class BrowserWorkflowTests: XCTestCase {
    private func store(_ disk: BrowserDisk = BrowserDisk(), controller: BrowserController, model: BrowserModel = BrowserModel()) -> PuddleStore {
        disk.state.settings.automaticallyLearn = false
        return PuddleStore(cache: disk, secrets: BrowserSecrets(), transport: model, reminderScheduler: BrowserReminders(), browserController: controller)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Browser fixture did not finish")
    }
    func testErrandRecordsRequireFreshPageEvidenceAndRemainPausedOnRestart() async throws {
        let disk = BrowserDisk(), controller = BrowserController(), store = store(disk, controller: controller)
        await store.start(); await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        let job = BrowserErrand(goal: "Find the fixture")
        try store.commit { $0.browserErrands = [job] }
        await store.verifyBrowserErrand(job.id, quote: "Invented confirmation")
        XCTAssertEqual(store.state.browserErrands.first?.status, .ready)
        await store.verifyBrowserErrand(job.id, quote: "Fixture browser page")
        XCTAssertEqual(store.state.browserErrands.first?.status, .completed)
        XCTAssertEqual(store.state.browserErrands.first?.evidence, "Fixture browser page")
        try store.commit { $0.browserErrands[0].status = .running }
        let restarted = self.store(disk, controller: BrowserController()); await restarted.start()
        XCTAssertEqual(restarted.state.browserErrands.first?.status, .paused)
        XCTAssertFalse(restarted.browserWorkspace.isConnected)
        store.suspendConnectionWork(); restarted.suspendConnectionWork(); store.browserWorkspace.stop()
    }

    func testBrowserToolsRequireExplicitLiveSessionAndDemoRevokesIt() async throws {
        let controller = BrowserController(), store = store(controller: controller); await store.start()
        XCTAssertFalse(store.availableTools.contains(.browserState))
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        XCTAssertTrue(store.availableTools.contains(.browserState)); XCTAssertTrue(store.availableTools.contains(.browserNavigate))
        XCTAssertTrue(store.availableTools.contains(.browserScroll))
        XCTAssertFalse(store.availableTools.contains(.browserClick)); XCTAssertFalse(store.availableTools.contains(.browserType))
        store.enterDemo()
        XCTAssertFalse(store.availableTools.contains(.browserState)); XCTAssertFalse(store.browserWorkspace.isConnected)
        let restarted = self.store(controller: BrowserController()); await restarted.start()
        XCTAssertFalse(restarted.availableTools.contains(.browserState))
    }
    func testFailedErrandSaveRejectsRequestWithoutStartingModelAndCanRetry() async throws {
        let disk = BrowserDisk(), controller = BrowserController(), subject = store(disk, controller: controller)
        await subject.start(); await subject.browserWorkspace.connect(path: "/fixture/cua-driver")
        defer { subject.stopAI(); subject.suspendConnectionWork(); subject.browserWorkspace.stop() }
        disk.failWrite = true
        let rejected = await subject.startBrowserErrand("Retain this synthetic browser goal")
        XCTAssertFalse(rejected); XCTAssertTrue(subject.state.browserErrands.isEmpty)
        XCTAssertTrue(subject.state.chat.isEmpty); XCTAssertFalse(subject.isThinking)
        disk.failWrite = false
        let accepted = await subject.startBrowserErrand("Retain this synthetic browser goal")
        XCTAssertTrue(accepted)
        try await wait { subject.pendingApproval != nil }
        XCTAssertEqual(subject.state.browserErrands.first?.goal, "Retain this synthetic browser goal")
        subject.resolveApproval(false); try await wait { !subject.isThinking }
        XCTAssertEqual(subject.state.browserErrands.count, 1)
    }
    func testActionWaitsForApprovalAndRetryReadsInsteadOfRepeating() async throws {
        let controller = BrowserController(), store = store(controller: controller); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        store.ask("Open a page in my browser")
        try await wait { store.pendingApproval != nil }
        let before = await controller.actions; XCTAssertEqual(before, 0)
        XCTAssertTrue(store.pendingApproval?.detail.contains("https://example.test/") == true)
        store.resolveApproval(true); try await wait { !store.isThinking }
        let after = await controller.actions; XCTAssertEqual(after, 1)
        XCTAssertEqual(store.state.chat.first(where: { $0.role == "user" })?.receipts?.first?.status, "completed")
        store.retryLastQuestion(); try await wait { !store.isThinking }
        let retried = await controller.actions; XCTAssertEqual(retried, 1)
        XCTAssertNil(store.pendingApproval)
        XCTAssertTrue(store.state.chat.first(where: { $0.role == "user" })?.receipts?.contains { $0.tool == "read_browser_page" } == true)
    }
    func testPausedErrandCannotReuseAnEarlierUnrelatedAssistantReply() async throws {
        let controller = BrowserController(), store = store(controller: controller); await store.start()
        try store.commit { $0.chat = [ChatLine(role: "assistant", content: "Unrelated earlier daily brief")] }
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        await store.startBrowserErrand("Open a synthetic page")
        try await wait { store.pendingApproval != nil }
        store.stopAI()
        let job = try XCTUnwrap(store.state.browserErrands.first)
        XCTAssertEqual(job.status, .paused)
        XCTAssertEqual(job.latestProgress, "Paused. Inspect the browser before continuing.")
        XCTAssertFalse(job.latestProgress.contains("daily brief"))
        store.browserWorkspace.stop(); store.suspendConnectionWork()
    }
    func testGuessedBrowserTargetNeverReachesApprovalOrDispatch() async throws {
        for ref in ["textbox Test note", "p1:button"] {
        let controller = BrowserController(), model = BrowserModel(); await model.requestTyping(ref: ref)
        let store = store(controller: controller, model: model); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        store.ask("Type into the test field"); try await wait { !store.isThinking }
        XCTAssertNil(store.pendingApproval)
        let actions = await controller.actions; XCTAssertEqual(actions, 0)
        XCTAssertFalse(store.state.chat.flatMap { $0.receipts ?? [] }.contains { $0.status == "pending" })
        store.browserWorkspace.stop(); store.suspendConnectionWork()
        }
    }
    func testLegacyTypingErrandCannotReachApprovalOrDispatchOnContinueOrRetry() async throws {
        let controller = BrowserController(), model = BrowserModel(); await model.requestTyping(ref: "p1:field")
        let store = store(controller: controller, model: model); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        await store.startBrowserErrand("Type a local test"); try await wait { !store.isThinking }
        XCTAssertTrue(store.state.chat.first { $0.role == "user" }?.content.contains("p1:field") == true)
        XCTAssertEqual(store.state.chat.first { $0.role == "user" }?.visibleText, "Type a local test")
        let job = try XCTUnwrap(store.state.browserErrands.first)
        await store.continueBrowserErrand(job.id); try await wait { !store.isThinking }
        store.retryLastQuestion(); try await wait { !store.isThinking }
        XCTAssertNil(store.pendingApproval)
        let actions = await controller.actions; XCTAssertEqual(actions, 0)
        XCTAssertFalse(store.state.chat.flatMap { $0.receipts ?? [] }.contains { $0.status == "pending" })
        let requests = await model.requests
        for request in requests where request.url?.path == "/v1/chat/completions" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let tools = body["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertFalse(names.contains("click_browser_element")); XCTAssertFalse(names.contains("type_in_browser"))
        }
        store.browserWorkspace.stop(); store.suspendConnectionWork()
    }
    func testHostileClickCallAndDirectWorkspaceWritesAreBlocked() async throws {
        for serialized in [false, true] {
        let controller = BrowserController(), model = BrowserModel(); await model.requestClick(ref: "p1:button", serialized: serialized)
        let store = store(controller: controller, model: model); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        store.ask("Click the changed target"); try await wait { !store.isThinking }
        XCTAssertNil(store.pendingApproval)
        for action in [CuaBrowserAction.click("p1:button"), .type(ref: "p1:field", text: "synthetic password", replace: true)] {
            do { _ = try await store.browserWorkspace.act(action); XCTFail("Injected controller received a deferred action") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unavailable in this release")) }
        }
        let count = await controller.actions; XCTAssertEqual(count, 0)
        XCTAssertFalse(store.browserWorkspace.isBusy)
        XCTAssertTrue(store.browserWorkspace.isConnected)
        _ = try await store.browserWorkspace.observe()
        _ = try await store.browserWorkspace.act(.navigate("https://example.test/"))
        let allowedCount = await controller.actions; XCTAssertEqual(allowedCount, 1)
        store.browserWorkspace.stop(); store.suspendConnectionWork()
        }
    }
    func testHistoricalWriteReceiptsRemainReadableAndRetryOnlyReads() async throws {
        for tool in [AgentTool.browserClick, .browserType] {
            let disk = BrowserDisk(), controller = BrowserController()
            var user = ChatLine(role: "user", content: "Continue the previous browser task")
            user.receipts = [ToolReceipt(id: "old-write", tool: tool.rawValue, detail: "Historical uncertain action", status: "unverified")]
            disk.state.chat = [user]
            let store = store(disk, controller: controller); await store.start()
            await store.browserWorkspace.connect(path: "/fixture/cua-driver")
            store.retryLastQuestion(); try await wait { !store.isThinking }
            XCTAssertNil(store.pendingApproval)
            let count = await controller.actions; XCTAssertEqual(count, 0)
            XCTAssertTrue(store.state.chat.first?.receipts?.contains { $0.id == "old-write" && $0.tool == tool.rawValue } == true)
            XCTAssertTrue(store.state.chat.first?.receipts?.contains { $0.tool == AgentTool.browserState.rawValue } == true)
            store.browserWorkspace.stop(); store.suspendConnectionWork()
        }
    }
    func testDeclineAndFailedIntentSaveNeverOperateBrowser() async throws {
        for failSave in [false, true] {
            let disk = BrowserDisk(), controller = BrowserController(), store = store(disk, controller: controller); await store.start()
            await store.browserWorkspace.connect(path: "/fixture/cua-driver")
            store.ask("Open a page in my browser"); try await wait { store.pendingApproval != nil }
            disk.failWrite = failSave; store.resolveApproval(failSave)
            try await wait { !store.isThinking }
            let count = await controller.actions; XCTAssertEqual(count, 0)
        }
    }
    func testUnverifiedActionCannotBeRepeatedOnRetry() async throws {
        let controller = BrowserController(); await controller.configure(failAfterDispatch: true)
        let store = store(controller: controller); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        store.ask("Open a page in my browser"); try await wait { store.pendingApproval != nil }
        store.resolveApproval(true); try await wait { !store.isThinking }
        XCTAssertEqual(store.state.chat.first(where: { $0.role == "user" })?.receipts?.first?.status, "unverified")
        store.retryLastQuestion(); try await wait { !store.isThinking }
        let count = await controller.actions; XCTAssertEqual(count, 1); XCTAssertNil(store.pendingApproval)
    }
    func testStopAndProfileSwitchCancelApprovalAndLateBrowserResult() async throws {
        let controller = BrowserController(), store = store(controller: controller); await store.start()
        await store.browserWorkspace.connect(path: "/fixture/cua-driver")
        store.ask("Open a page in my browser"); try await wait { store.pendingApproval != nil }
        store.chooseDeveloperProfile()
        XCTAssertNil(store.pendingApproval)
        let before = await controller.actions; XCTAssertEqual(before, 0)

        await controller.configure(delay: true)
        store.ask("Open a page now"); try await wait { store.pendingApproval != nil }
        store.resolveApproval(true)
        try await wait { store.browserWorkspace.isBusy }
        store.stopAI(); store.browserWorkspace.stop()
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(store.browserWorkspace.isConnected); XCTAssertNil(store.browserWorkspace.page)
        XCTAssertFalse(store.isThinking)
        XCTAssertEqual(store.state.chat.last?.role, "user")
    }
}
