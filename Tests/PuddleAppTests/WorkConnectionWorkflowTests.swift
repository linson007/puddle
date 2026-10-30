import Foundation
import XCTest
@testable import PuddleCore
@testable import Puddle

private final class WorkAppSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failDelete = false
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; if failDelete { throw PuddleError("Keychain delete failed") }; values[key] = nil }
    func seedAtlassian() throws {
        var value = AtlassianCredentials(accessToken: "atlassian-secret", refreshToken: "refresh-secret", expiresAt: Date().addingTimeInterval(3600), clientID: "client", endpoints: AtlassianOAuthEndpoints(issuer: URL(string: "https://auth.atlassian.com/tenant")!, authorize: URL(string: "https://auth.atlassian.com/authorize")!, token: URL(string: "https://auth.atlassian.com/oauth/token")!, registration: URL(string: "https://auth.atlassian.com/dcr")!), scopes: ["read:me"], services: [.jira])
        value.sites = [AtlassianSite(id: "cloud-1", name: "Fixture site", url: URL(string: "https://fixture.atlassian.net")!)]; value.selectedSiteID = "cloud-1"
        try write(JSONEncoder().encode(value), key: "atlassian-connector-v1")
    }
}
private final class WorkAppDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    func load() throws -> AppSnapshot { state }
    func save(_ value: AppSnapshot) throws { state = value }
}
@MainActor private final class WorkAppReminders: ReminderScheduling { func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {} }
private actor WorkAppHTTP: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var generation = 0
    var denyGitHub = false
    func deny() { denyGitHub = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        var status = 200
        let body: [String: Any]
        switch request.url!.host! {
        case "api.github.com":
            if denyGitHub { status = 401; body = ["message": "secret-provider-details"] }
            else if path == "/user" { body = ["login": "alice"] }
            else if path == "/search/issues" { body = ["total_count": 1, "items": [["repository_url": "https://api.github.com/repos/acme/app", "number": 7, "title": "Fix timeout", "state": "open", "body": "Requirement: respect cancellation"]]] }
            else if path == "/repos/acme/app/issues" || path == "/repos/acme/app/pulls" { return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            else if path.hasSuffix("/comments") { return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            else if path.contains("/issues/") { body = ["title": "Fix timeout", "state": "open", "body": "Requirement: respect cancellation", "comments": 0] }
            else { body = ["full_name": "acme/app"] }
        case "mcp.atlassian.com": status = 401; body = ["message": "revoked"]
        default:
            if path == "/ready" { body = ["status": "ready"] }
            else if path == "/v1/models" { body = ["data": [["id": "fixture", "max_model_len": 32768]]] }
            else {
                generation += 1
                let tool: String, arguments: [String: String]
                if generation == 1 { tool = "search_connected_work"; arguments = ["query": "timeout", "service": "all", "syntax": "text"] }
                else { tool = "read_connected_work_item"; arguments = ["service": "github", "locator": "acme/app#7", "view": "details"] }
                if generation <= 2 { body = ["choices": [["message": ["tool_calls": [["id": "step-\(generation)", "type": "function", "function": ["name": tool, "arguments": arguments]]]], "finish_reason": "tool_calls"]]] }
                else { body = ["choices": [["message": ["content": "The timeout issue requires cancellation handling. Jira could not be read. https://github.com/acme/app/issues/7"], "finish_reason": "stop"]]] }
            }
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class WorkConnectionWorkflowTests: XCTestCase {
    private func store(secrets: WorkAppSecrets = WorkAppSecrets(), http: WorkAppHTTP = WorkAppHTTP(), disk: WorkAppDisk = WorkAppDisk()) -> PuddleStore {
        PuddleStore(cache: disk, secrets: secrets, transport: http, reminderScheduler: WorkAppReminders())
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }; XCTFail("Workflow did not complete")
    }
    func testSearchThenReadRoundTripPreservesPartialFailuresAndSourceReceipts() async throws {
        let secrets = WorkAppSecrets(), http = WorkAppHTTP(), disk = WorkAppDisk(); try secrets.seedAtlassian()
        let app = store(secrets: secrets, http: http, disk: disk); await app.start()
        let connected = await app.connectGitHub(token: "github-secret", repositories: ["acme/app"]); XCTAssertTrue(connected)
        XCTAssertTrue(app.availableTools.contains(.searchConnectedWork)); XCTAssertTrue(app.availableTools.contains(.readConnectedWork))
        app.chooseDeveloperProfile(); app.ask("What needs fixing for timeout?")
        try await wait { !app.isThinking }
        XCTAssertTrue(app.state.chat.last?.content.contains("cancellation") == true)
        let receipts = try XCTUnwrap(app.state.chat.first { $0.role == "user" }?.receipts)
        XCTAssertEqual(receipts.map(\.tool), ["search_connected_work", "read_connected_work_item"])
        XCTAssertTrue(receipts.allSatisfy { $0.status == "completed" })
        XCTAssertTrue(receipts[0].detail.contains("Some sources failed")); XCTAssertEqual(receipts[1].references[0].url.absoluteString, "https://github.com/acme/app/issues/7")
        let modelRequests = (await http.requests).filter { $0.url?.path == "/v1/chat/completions" }
        let text = String(decoding: try XCTUnwrap(modelRequests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("respect cancellation")); XCTAssertTrue(text.contains("revoked"))
        XCTAssertFalse(text.contains("github-secret")); XCTAssertFalse(text.contains("atlassian-secret")); XCTAssertFalse(text.contains("refresh-secret"))
        let persisted = String(decoding: try JSONEncoder().encode(disk.state), as: UTF8.self)
        XCTAssertFalse(persisted.contains("github-secret")); XCTAssertFalse(persisted.contains("atlassian-secret"))
        let restored = store(secrets: secrets, http: http, disk: disk); await restored.start()
        XCTAssertEqual(restored.connectedWorkServices, [.github, .jira])
    }
    func testAllFailedSearchThrowsAndDisconnectedOrDemoToolsCannotReadAccounts() async throws {
        let http = WorkAppHTTP(), app = store(http: http); await app.start()
        XCTAssertFalse(app.availableTools.contains(.searchConnectedWork))
        _ = await app.connectGitHub(token: "github-secret", repositories: ["acme/app"]); await http.deny()
        do { _ = try await app.searchConnectedWork("", service: "all", syntax: "text"); XCTFail("All-failed search reported success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("search failed")); XCTAssertFalse(error.localizedDescription.contains("secret-provider-details")) }
        let count = await http.requests.count
        app.enterDemo()
        XCTAssertFalse(app.availableTools.contains(.searchConnectedWork)); XCTAssertFalse(app.availableTools.contains(.readConnectedWork))
        do { _ = try await app.readConnectedWork(service: "github", locator: "acme/app#7", view: "details"); XCTFail("Demo accessed an account") } catch {}
        let after = await http.requests.count; XCTAssertEqual(count, after)
    }
    func testFailedDisconnectKeepsAccountStatusAndSuccessfulDisconnectClearsResults() async throws {
        let secrets = WorkAppSecrets(), http = WorkAppHTTP(), app = store(secrets: secrets, http: http); await app.start()
        _ = await app.connectGitHub(token: "github-secret", repositories: ["acme/app"])
        app.workSources.search(query: "", services: [.github], github: app.githubConnector, atlassian: app.atlassianConnector)
        try await wait { !app.workSources.isSearching }; XCTAssertEqual(app.workSources.results.count, 1)
        secrets.failDelete = true; await app.disconnectWorkConnection(.github)
        XCTAssertNotNil(app.githubConnection); XCTAssertNotNil(app.workConnectionErrors[.github])
        secrets.failDelete = false; await app.disconnectWorkConnection(.github)
        XCTAssertNil(app.githubConnection); XCTAssertTrue(app.workSources.results.isEmpty); XCTAssertFalse(app.availableTools.contains(.searchConnectedWork))
    }
    func testAssistantSearchSummaryFitsContextAndMarksOmittedItems() throws {
        let items = (1...10).map { WorkItem(service: .github, locator: "acme/app#\($0)", title: String(repeating: "Title", count: 100), detail: String(repeating: "detail", count: 100), excerpt: String(repeating: "description", count: 200), url: URL(string: "https://github.com/acme/app/issues/\($0)")!) }
        let result = ConnectedWorkSearch(results: [WorkReadResult(service: .github, title: "Search", items: items, scope: "First 10")], errors: [:])
        XCTAssertLessThan(try result.encoded.count, 4000); XCTAssertEqual(result.sources[0].items.count, 3); XCTAssertTrue(result.sources[0].hasMore)
        XCTAssertEqual(result.references.count, 3)
    }
    func testPastedRepositoryURLFormConnectsAndRestoresCanonicalScope() async throws {
        let secrets = WorkAppSecrets(), http = WorkAppHTTP(), app = store(secrets: secrets, http: http)
        let connected = await app.connectGitHub(token: "github-secret", repositoryText: " https://github.com/Acme/App/\nacme/app, https://github.com/acme/app.git?token=private-input#readme ")
        XCTAssertTrue(connected); XCTAssertEqual(app.githubConnection?.repositories, ["acme/app"])
        XCTAssertNil(app.workConnectionErrors[.github]); XCTAssertFalse(app.isConnectingGitHub)
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/user", "/repos/acme/app", "/repos/acme/app/issues", "/repos/acme/app/pulls"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.url?.absoluteString.contains("private-input") == false })
        let restarted = store(secrets: secrets, http: http); await restarted.loadWorkConnections()
        XCTAssertEqual(restarted.githubConnection?.repositories, ["acme/app"])
    }
    func testRepositoryFormShowsSpecificErrorsAndKeepsExistingConnection() async throws {
        let http = WorkAppHTTP(), app = store(http: http)
        _ = await app.connectGitHub(token: "github-secret", repositories: ["acme/app"])
        let previous = app.githubConnection, before = await http.requests.count
        let badRepository = await app.connectGitHub(token: "github-secret", repositoryText: "https://github.com/acme/app/issues/7")
        XCTAssertFalse(badRepository); XCTAssertEqual(app.githubConnection, previous)
        XCTAssertTrue(app.workConnectionErrors[.github]?.contains("Repository entry 1") == true)
        let badToken = await app.connectGitHub(token: "", repositoryText: "https://github.com/acme/app")
        XCTAssertFalse(badToken); XCTAssertTrue(app.workConnectionErrors[.github]?.contains("token field") == true)
        XCTAssertEqual(app.githubConnection, previous); XCTAssertFalse(app.isConnectingGitHub)
        let after = await http.requests.count; XCTAssertEqual(before, after)
    }
}
