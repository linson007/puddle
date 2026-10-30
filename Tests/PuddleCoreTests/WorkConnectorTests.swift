import Foundation
import XCTest
@testable import PuddleCore

private final class WorkSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrite = false
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw PuddleError("Keychain unavailable") }; values[key] = data }
    func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor WorkHTTP: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var hostileMetadata = false
    var missingTools = false
    var useSSE = false
    var expireNext = false
    var holdRefresh = false
    var refreshWaiter: CheckedContinuation<Void, Never>?
    var refreshStarted = false
    var siteCount = 1
    var rawSearch = false
    var denyGitHub = false
    var redirectGitHub = false
    func configure(hostile: Bool = false, missing: Bool = false, sse: Bool = false, sites: Int = 1, raw: Bool = false) {
        hostileMetadata = hostile; missingTools = missing; useSSE = sse; siteCount = sites; rawSearch = raw
    }
    func expireSession() { expireNext = true }
    func blockRefresh() { holdRefresh = true }
    func releaseRefresh() { refreshWaiter?.resume(); refreshWaiter = nil; holdRefresh = false }
    func deny() { denyGitHub = true }
    func redirect() { redirectGitHub = true }
    private func response(_ request: URLRequest, _ value: Any, status: Int = 200, headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        if request.url!.host == "api.github.com" {
            if redirectGitHub { return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://evil.example/stolen")!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if denyGitHub || request.value(forHTTPHeaderField: "Authorization") == "Bearer bad-token" { return try response(request, ["message": "private-token-leak"], status: 403) }
            if path == "/user" { return try response(request, ["login": "alice"]) }
            if path == "/repos/acme/app" { return try response(request, ["full_name": "acme/app"]) }
            if path == "/repos/acme/app/issues" || path == "/repos/acme/app/pulls" {
                return try response(request, [], status: request.value(forHTTPHeaderField: "Authorization") == "Bearer metadata-only" ? 403 : 200)
            }
            if path == "/search/issues" {
                return try response(request, ["total_count": 3, "incomplete_results": false, "items": [
                    ["repository_url": "https://api.github.com/repos/acme/app", "number": 7, "title": "Fix timeout", "state": "open", "body": "Retry safely", "pull_request": ["url": "ignored"]],
                    ["repository_url": "https://api.github.com/repos/other/private", "number": 8, "title": "Outside scope"],
                    ["repository_url": "https://api.github.com/repos/acme/app", "number": 7.5, "title": "Malformed"]
                ]])
            }
            if path.hasSuffix("/comments") { return try response(request, [["user": ["login": "bob"], "body": "Review cancellation"]]) }
            if path.hasSuffix("/files") { return try response(request, [["filename": "Main.swift", "status": "modified", "patch": "+checkCancellation()"], ["filename": "image.png", "status": "added"]], headers: ["Link": "<unused>; rel=\"next\""] ) }
            if path.hasSuffix("/check-runs") { return try response(request, ["total_count": 1, "check_runs": [["name": "tests", "status": "completed", "conclusion": "success"]]]) }
            if path == "/repos/acme/app/pulls/7" { return try response(request, ["head": ["sha": String(repeating: "a", count: 40)]]) }
            if path == "/repos/acme/app/issues/7" { return try response(request, ["title": "Fix timeout", "state": "open", "body": "Required behavior", "comments": 9, "updated_at": "2026-10-29", "pull_request": [:]]) }
            return try response(request, [:], status: 404)
        }
        if path == "/.well-known/oauth-protected-resource/v2/mcp" {
            return try response(request, ["resource": "https://mcp.atlassian.com/v2/mcp", "authorization_servers": ["https://auth.atlassian.com/tenant"], "scopes_supported": ["read:me", "offline_access", "read:jira:agent-interface", "search:jira:agent-interface", "read:confluence:agent-interface", "search:confluence:agent-interface"]])
        }
        if path == "/.well-known/oauth-authorization-server/tenant" {
            return try response(request, ["issuer": "https://auth.atlassian.com/tenant", "authorization_endpoint": "https://auth.atlassian.com/authorize", "token_endpoint": hostileMetadata ? "https://evil.example/token" : "https://auth.atlassian.com/oauth/token", "registration_endpoint": "https://auth.atlassian.com/tenant/dcr/register", "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]])
        }
        if path == "/tenant/dcr/register" { return try response(request, ["client_id": "public-local-client", "token_endpoint_auth_method": "none"]) }
        if path == "/oauth/token" {
            if String(decoding: request.httpBody!, as: UTF8.self).contains("grant_type=refresh_token") {
                refreshStarted = true
                if holdRefresh { await withCheckedContinuation { refreshWaiter = $0 } }
                else { try await Task.sleep(for: .milliseconds(30)) }
                return try response(request, ["access_token": "rotated-access", "refresh_token": "rotated-refresh", "token_type": "Bearer", "expires_in": 3600])
            }
            return try response(request, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "Bearer", "expires_in": 3600])
        }
        guard path == "/v2/mcp", let bytes = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let method = body["method"] as? String else { throw PuddleError("Unexpected fixture request") }
        if method == "notifications/initialized" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!) }
        if expireNext && method == "tools/call" { expireNext = false; return try response(request, [:], status: 404) }
        let result: Any
        if method == "initialize" { result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "fixture", "version": "1"]] }
        else if method == "tools/list" { result = ["tools": (missingTools ? ["getAccessibleAtlassianResources"] : Array(AtlassianMCP.permittedTools) + ["executeWrite"]).map { ["name": $0] }] }
        else {
            let params = body["params"] as! [String: Any], name = params["name"] as! String
            let content: Any
            switch name {
            case "getAccessibleAtlassianResources": content = (1...siteCount).map { ["id": "cloud-\($0)", "name": "Site \($0)", "url": "https://site\($0).atlassian.net"] }
            case "searchJiraIssuesUsingJql": content = ["issues": [["key": "DEV-42", "fields": ["summary": "Retry safely", "status": ["name": "In Progress"], "description": "Respect cancellation"]]], "isLast": false]
            case "searchConfluence": content = ["results": [["content": ["id": "123", "title": "Architecture", "type": "page", "url": "https://evil.example/not-a-source"], "excerpt": "<b>Local</b> inference"]], "_links": ["next": "not-followed"]]
            case "getJiraIssue": content = ["key": "DEV-42", "fields": ["summary": "Retry safely", "status": ["name": "In Progress"], "description": "Respect cancellation", "assignee": ["displayName": "Alice"]]]
            case "getConfluenceContent": content = ["id": "123", "title": "Architecture", "body": ["value": "# Local architecture\nModel stays local.", "representation": "markdown"]]
            default: throw PuddleError("Forbidden fixture operation")
            }
            if rawSearch && name.hasPrefix("search") { result = ["content": [["type": "text", "text": "Unstructured result with incomplete locators"]]] }
            else { result = ["structuredContent": content, "isError": false] as [String: Any] }
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"]!, "result": result]
        if useSSE {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            return (Data(": heartbeat\r\nevent: message\r\ndata: \(text)\r\n\r\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "fixture-session"])!)
        }
        return try response(request, envelope, headers: ["Content-Type": "application/json", "Mcp-Session-Id": "fixture-session"])
    }
}

final class WorkConnectorTests: XCTestCase {
    private let redirect = URL(string: "http://127.0.0.1:8765/oauth/callback")!
    private func signIn(_ connector: AtlassianConnector, services: Set<WorkService> = [.jira, .confluence]) async throws -> AtlassianConnectionInfo {
        let attempt = try await connector.prepare(redirect: redirect, services: services)
        return try await connector.finish(attempt, code: "fixture-code")
    }
    func testGitHubReadWorkflowIsScopedReadOnlyAndCitesCanonicalSources() async throws {
        let secrets = WorkSecrets(), http = WorkHTTP(), connector = GitHubConnector(secrets: secrets, transport: http)
        let info = try await connector.connect(token: "private-token", repositories: ["Acme/App", "acme/app"])
        XCTAssertEqual(info.login, "alice"); XCTAssertEqual(info.repositories, ["acme/app"])
        let search = try await connector.search("timeout repo:other/private")
        XCTAssertEqual(search.items.map(\.locator), ["acme/app#7"]); XCTAssertTrue(search.hasMore)
        XCTAssertEqual(search.items[0].url.absoluteString, "https://github.com/acme/app/pull/7")
        let details = try await connector.read(repository: "acme/app", number: 7, view: "details")
        XCTAssertTrue(details.text.contains("Review cancellation")); XCTAssertTrue(details.hasMore)
        let diff = try await connector.read(repository: "acme/app", number: 7, view: "diff")
        XCTAssertTrue(diff.text.contains("checkCancellation()")); XCTAssertTrue(diff.text.contains("No text patch")); XCTAssertTrue(diff.hasMore)
        let checks = try await connector.read(repository: "acme/app", number: 7, view: "checks")
        XCTAssertTrue(checks.text.contains("success")); XCTAssertTrue(checks.scope.contains("did not run"))
        let requests = await http.requests
        XCTAssertTrue(requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" && $0.url?.host == "api.github.com" })
        let q = URLComponents(url: requests.first { $0.url?.path == "/search/issues" }!.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
        XCTAssertEqual(q, "\"timeout repo:other/private\" repo:acme/app")
        XCTAssertFalse(search.encoded.contains("private-token"))
        let restored = GitHubConnector(secrets: secrets, transport: http)
        let restoredInfo = try await restored.info(); XCTAssertEqual(restoredInfo?.login, "alice")
        try await connector.disconnect(); let disconnected = try await connector.info(); XCTAssertNil(disconnected)
    }
    func testGitHubValidationAndFailedReplacementPreserveConnection() async throws {
        XCTAssertFalse(GitHubConnector.repository("acme/.")); XCTAssertFalse(GitHubConnector.repository("acme/..")); XCTAssertFalse(GitHubConnector.repository("acme/app/other"))
        let secrets = WorkSecrets(), http = WorkHTTP(), connector = GitHubConnector(secrets: secrets, transport: http)
        _ = try await connector.connect(token: "good-token", repositories: ["acme/app"])
        let count = await http.requests.count
        do { _ = try await connector.read(repository: "other/private", number: 7, view: "details"); XCTFail("Outside repository allowed") } catch {}
        let after = await http.requests.count; XCTAssertEqual(count, after)
        do { _ = try await connector.connect(token: "bad-token", repositories: ["acme/app"]); XCTFail("Failed authorization accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-token-leak")) }
        let info = try await connector.info(); XCTAssertEqual(info?.repositories, ["acme/app"])
        do { _ = try await connector.connect(token: "metadata-only", repositories: ["acme/app"]); XCTFail("Metadata-only access reported ready") } catch {}
        secrets.failWrite = true
        do { _ = try await connector.connect(token: "replacement", repositories: ["acme/app"]); XCTFail("Failed Keychain write accepted") } catch {}
        XCTAssertTrue(String(decoding: try XCTUnwrap(secrets.read("github-connector-v1")), as: UTF8.self).contains("good-token"))
    }
    func testGitHubConnectionAcceptsPastedRepositoryURLs() async throws {
        let http = WorkHTTP(), connector = GitHubConnector(secrets: WorkSecrets(), transport: http)
        let info = try await connector.connect(token: "fixture-token", repositories: [
            "https://github.com/Acme/App", "https://github.com/acme/app/", "acme/app",
            "https://github.com/acme/app.git", "https://github.com/acme/app?tab=readme-ov-file#readme"
        ])
        XCTAssertEqual(info.repositories, ["acme/app"])
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/user", "/repos/acme/app", "/repos/acme/app/issues", "/repos/acme/app/pulls"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.url?.fragment == nil })
    }
    func testGitHubRepositoryFormParsesURLsNamesSeparatorsAndDuplicates() throws {
        let inputs = [
            "acme/app", " Acme/App \n", "https://github.com/Acme/App", "https://github.com/acme/app/",
            "https://github.com/acme/app.git", "https://github.com/acme/app.git/",
            "https://github.com/acme/app?tab=readme-ov-file#readme", "HTTPS://GITHUB.COM/Acme/App",
            "https://www.github.com/acme/app", "https://github.com:443/acme/app", "github.com/Acme/App"
        ]
        for input in inputs { XCTAssertEqual(try GitHubConnector.parseRepositories(input), ["acme/app"], input) }
        let mixed = "\nhttps://github.com/Zeta/Other/ , acme/app\r\nhttps://github.com/Acme/App.git\tACME/APP  "
        XCTAssertEqual(try GitHubConnector.parseRepositories(mixed), ["acme/app", "zeta/other"])
        XCTAssertEqual(try GitHubConnector.parseRepositories(Array(repeating: "https://github.com/acme/app", count: 12).joined(separator: "\n")), ["acme/app"])
    }
    func testGitHubRejectsUntrustedAndAmbiguousRepositoryURLsBeforeNetwork() async throws {
        let http = WorkHTTP(), connector = GitHubConnector(secrets: WorkSecrets(), transport: http)
        let inputs = [
            "http://github.com/acme/app", "https://github.com.evil.test/acme/app", "https://github.com@evil.test/acme/app",
            "https://secret-user:fixture-secret@github.com/acme/app", "https://github.com:8443/acme/app",
            "https://github.com/acme/app/issues/7", "https://github.com/acme/app/tree/main", "https://github.com/acme",
            "https://github.com/acme/../app", "https://github.com/acme/%2e%2e", "https://github.com/acme/app%2Ffiles",
            "https://github.com//acme/app", "https://github.com/acme/app//", "https://github.com/acme/app%0A", "https://github.com/acme/app%0D", "acme/.."
        ]
        for input in inputs {
            do { _ = try await connector.connect(token: "fixture-token", repositories: [input]); XCTFail("Invalid URL accepted") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("Repository entry 1"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-secret")); XCTAssertFalse(error.localizedDescription.contains("fixture-token"))
            }
        }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testGitHubInputErrorsIdentifyTheFieldAndCountWithoutEchoingSecrets() async throws {
        let http = WorkHTTP(), connector = GitHubConnector(secrets: WorkSecrets(), transport: http)
        do { _ = try await connector.connect(token: " \n", repositories: ["acme/app"]); XCTFail("Missing token accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("token field")) }
        do { _ = try await connector.connect(token: "Bearer fixture-secret", repositories: ["acme/app"]); XCTFail("Header pasted as token accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("token value")); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        do { _ = try await connector.connect(token: "fixture-token", repositories: []); XCTFail("Missing repository accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("at least one repository")) }
        do { _ = try await connector.connect(token: "fixture-token", repositories: (1...11).map { "acme/app\($0)" }); XCTFail("More than ten repositories accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("up to 10")) }
        XCTAssertThrowsError(try GitHubConnector.parseRepositories("acme/app, https://github.com/acme/app/issues/7")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Repository entry 2"))
        }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testGitHubRejectsRedirectsRatherThanTrustingReturnedContent() async throws {
        let http = WorkHTTP(); await http.redirect()
        let connector = GitHubConnector(secrets: WorkSecrets(), transport: http)
        do { _ = try await connector.connect(token: "private-token", repositories: ["acme/app"]); XCTFail("Redirect accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("redirected")) }
    }
    func testAtlassianPublicClientDiscoveryPKCEStateAndReadOnlyScopes() async throws {
        let http = WorkHTTP(), auth = AtlassianAuthorization(secrets: WorkSecrets(), transport: http)
        let attempt = try await auth.prepare(redirect: redirect, services: [.jira, .confluence])
        let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(query.contains { $0.name == "client_secret" || $0.name == "code_verifier" })
        XCTAssertTrue(attempt.scopes.contains("offline_access")); XCTAssertFalse(attempt.scopes.contains { $0.hasPrefix("write:") || $0.hasPrefix("delete:") })
        XCTAssertEqual(try attempt.code(from: URL(string: "\(redirect)?code=hello&state=\(attempt.state)")!), "hello")
        for url in ["\(redirect)?code=x&state=wrong", "http://localhost:8765/oauth/callback?code=x&state=\(attempt.state)", "\(redirect)?code=x&state=\(attempt.state)&state=\(attempt.state)", "\(redirect)?error=access_denied&state=\(attempt.state)"] {
            XCTAssertThrowsError(try attempt.code(from: URL(string: url)!))
        }
        _ = try await auth.exchange(attempt, code: "code+special")
        let requests = await http.requests
        let registration = requests.first { $0.url?.path.hasSuffix("/register") == true }!
        let body = try JSONDecoder().decode(ConnectorJSON.self, from: registration.httpBody!)
        XCTAssertEqual(body["token_endpoint_auth_method"]?.string, "none")
        let token = String(decoding: requests.last!.httpBody!, as: UTF8.self)
        XCTAssertTrue(token.contains("code_verifier=\(attempt.verifier)")); XCTAssertTrue(token.contains("code=code%2Bspecial"))
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    func testUntrustedOAuthMetadataFailsBeforeRegistrationOrTokenTransfer() async throws {
        let http = WorkHTTP(); await http.configure(hostile: true)
        let connector = AtlassianConnector(secrets: WorkSecrets(), transport: http)
        do { _ = try await connector.prepare(redirect: redirect, services: [.jira]); XCTFail("Untrusted token destination accepted") } catch {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2); XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil && $0.url?.host != "evil.example" })
    }
    func testAtlassianSearchReadAndConcurrentInitializationUsingSSE() async throws {
        let http = WorkHTTP(); await http.configure(sse: true)
        let secrets = WorkSecrets(), connector = AtlassianConnector(secrets: secrets, transport: http)
        let info = try await signIn(connector); XCTAssertEqual(info.selectedSiteID, "cloud-1")
        let before = await http.requests.count
        async let jiraRead = connector.search("", service: .jira)
        async let confluenceRead = connector.search("architecture", service: .confluence)
        let (jira, confluence) = try await (jiraRead, confluenceRead)
        XCTAssertEqual(jira.items[0].locator, "DEV-42"); XCTAssertTrue(jira.hasMore)
        XCTAssertTrue(jira.scope.contains("assigned to you"))
        XCTAssertEqual(confluence.items[0].locator, "123"); XCTAssertTrue(confluence.hasMore)
        XCTAssertEqual(confluence.items[0].url.host, "site1.atlassian.net")
        let details = try await connector.read("DEV-42", service: .jira)
        XCTAssertTrue(details.text.contains("In Progress")); XCTAssertTrue(details.text.contains("Alice"))
        let page = try await connector.read("123", service: .confluence)
        XCTAssertTrue(page.text.contains("Model stays local")); XCTAssertEqual(page.references[0].url.host, "site1.atlassian.net")
        let requests = Array((await http.requests).dropFirst(before))
        let bodies = try requests.compactMap(\.httpBody).map { try JSONDecoder().decode(ConnectorJSON.self, from: $0) }
        XCTAssertEqual(bodies.filter { $0["method"]?.string == "initialize" }.count, 1)
        let calls = bodies.filter { $0["method"]?.string == "tools/call" }
        XCTAssertTrue(calls.allSatisfy { AtlassianMCP.permittedTools.contains($0["params"]?["name"]?.string ?? "") })
        XCTAssertTrue(calls.allSatisfy { $0["params"]?["arguments"]?["cloudId"]?.string == "cloud-1" })
        XCTAssertFalse(page.encoded.contains("fixture-access"))
        try await connector.disconnect(); let none = try await connector.info(); XCTAssertNil(none)
    }
    func testMultipleAtlassianSitesRequireSelectionAndRejectUnknownSite() async throws {
        let http = WorkHTTP(); await http.configure(sites: 2)
        let connector = AtlassianConnector(secrets: WorkSecrets(), transport: http)
        let info = try await signIn(connector); XCTAssertNil(info.selectedSiteID)
        do { _ = try await connector.search("", service: .jira); XCTFail("Ambiguous site searched") } catch {}
        do { _ = try await connector.selectSite("unknown"); XCTFail("Unknown site accepted") } catch {}
        _ = try await connector.selectSite("cloud-2")
        let results = try await connector.search("", service: .jira)
        XCTAssertEqual(results.items.first?.url.host, "site2.atlassian.net")
    }
    func testMissingToolsDoesNotPersistAnIncompleteConnection() async throws {
        let http = WorkHTTP(); await http.configure(missing: true)
        let connector = AtlassianConnector(secrets: WorkSecrets(), transport: http)
        do { _ = try await signIn(connector); XCTFail("Missing tools accepted") } catch {}
        let info = try await connector.info(); XCTAssertNil(info)
    }
    func testUnstructuredSearchIsExplicitlyIncompleteRatherThanEmpty() async throws {
        let http = WorkHTTP(); await http.configure(raw: true)
        let connector = AtlassianConnector(secrets: WorkSecrets(), transport: http)
        _ = try await signIn(connector)
        let result = try await connector.search("x", service: .jira)
        XCTAssertTrue(result.items.isEmpty); XCTAssertTrue(result.hasMore); XCTAssertTrue(result.text.contains("Unstructured")); XCTAssertEqual(result.references.count, 1)
    }
    func testMCPRejectsWriteToolsBeforeNetworkAndRecoversExpiredReadSession() async throws {
        let http = WorkHTTP(), client = AtlassianMCP(transport: http, authorization: { "private-token" })
        do { _ = try await client.call("executeWrite", arguments: [:]); XCTFail("Write allowed") } catch {}
        let empty = await http.requests.count; XCTAssertEqual(empty, 0)
        _ = try await client.tools(); await http.expireSession()
        let result = try await client.call("getJiraIssue", arguments: ["cloudId": .string("cloud-1"), "issueIdOrKey": .string("DEV-42")])
        XCTAssertTrue(result.text.contains("Retry safely"))
        let requests = await http.requests
        let bodies = try requests.compactMap(\.httpBody).map { try JSONDecoder().decode(ConnectorJSON.self, from: $0) }
        XCTAssertEqual(bodies.filter { $0["method"]?.string == "initialize" }.count, 2)
    }
    private func expiredCredentials() -> AtlassianCredentials {
        AtlassianCredentials(accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast, clientID: "local", endpoints: AtlassianOAuthEndpoints(issuer: URL(string: "https://auth.atlassian.com/tenant")!, authorize: URL(string: "https://auth.atlassian.com/authorize")!, token: URL(string: "https://auth.atlassian.com/oauth/token")!, registration: URL(string: "https://auth.atlassian.com/tenant/dcr/register")!), scopes: ["read:me"], services: [.jira])
    }
    func testRefreshIsCoalescedAndRotatedTokensArePersisted() async throws {
        let http = WorkHTTP(), auth = AtlassianAuthorization(secrets: WorkSecrets(), transport: http)
        try await auth.install(expiredCredentials())
        async let first = auth.token(); async let second = auth.token()
        let values = try await [first, second]; XCTAssertEqual(values, ["rotated-access", "rotated-access"])
        let requests = await http.requests; XCTAssertEqual(requests.count, 1)
        let credentials = try await auth.load(); XCTAssertEqual(credentials?.refreshToken, "rotated-refresh")
    }
    func testDisconnectDuringRefreshCannotRestoreCredentials() async throws {
        let http = WorkHTTP(); await http.blockRefresh()
        let auth = AtlassianAuthorization(secrets: WorkSecrets(), transport: http); try await auth.install(expiredCredentials())
        let work = Task { try await auth.token() }
        for _ in 0..<200 { if await http.refreshStarted { break }; try await Task.sleep(for: .milliseconds(2)) }
        let started = await http.refreshStarted; XCTAssertTrue(started)
        try await auth.disconnect(); await http.releaseRefresh()
        do { _ = try await work.value; XCTFail("Disconnected refresh succeeded") } catch {}
        let restored = try await auth.load(); XCTAssertNil(restored)
    }
    func testReadBoundsAndRateLimitErrorsNeverEchoProviderBodies() async throws {
        let result = WorkReadResult(service: .jira, title: "Large", text: String(repeating: "x", count: 20_000), scope: "bounded")
        XCTAssertEqual(result.text.count, 12_000); XCTAssertTrue(result.hasMore)
        let transport = LimitedWorkHTTP()
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!); request.httpMethod = "GET"
        do { _ = try await WorkConnectorHTTP.send(request, transport: transport, service: "GitHub", hosts: ["api.github.com"]); XCTFail("Rate limit accepted") }
        catch let error as HTTPServiceError { XCTAssertEqual(error.statusCode, 429); XCTAssertEqual(error.retryAfter, 120); XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
    func testStaleAuthorizationInstallAndVerificationCannotUndoDisconnect() async throws {
        let auth = AtlassianAuthorization(secrets: WorkSecrets(), transport: WorkHTTP())
        let value = expiredCredentials(); try await auth.install(value)
        let expected = await auth.generation(); try await auth.disconnect()
        do { try await auth.install(value, expected: expected); XCTFail("Stale sign-in restored credentials") } catch is CancellationError {}
        do { _ = try await auth.verified(sites: [], selectedSiteID: nil, at: Date(), expected: expected); XCTFail("Stale verification restored credentials") } catch is CancellationError {}
        let current = await auth.generation()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await auth.install(value, expected: current)
        }
        do { try await cancelled.value; XCTFail("Cancelled sign-in installed credentials") } catch is CancellationError {}
        let info = try await auth.load(); XCTAssertNil(info)
    }
    func testSSEStopsOnlyAfterMatchingCompletedResponseAndRejectsMismatchedID() async throws {
        let transport = WorkStreamHTTP()
        let client = AtlassianMCP(transport: transport, authorization: { "private-access" })
        let tools = try await client.tools(); XCTAssertTrue(tools.contains("getJiraIssue"))
        let stopped = await transport.stopped; XCTAssertEqual(stopped, 2)
        await transport.mismatch()
        do { _ = try await client.call("getJiraIssue", arguments: [:]); XCTFail("Mismatched RPC ID accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unmatched")) }
    }
}

private struct LimitedWorkHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { (Data("secret-provider-error".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!) }
}

private actor WorkStreamHTTP: HTTPTransport {
    private(set) var stopped = 0
    private var mismatched = false
    func mismatch() { mismatched = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw PuddleError("Unbounded transport must not be used") }
    func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(maximumBytes, 2 * 1024 * 1024)
        let input = try JSONDecoder().decode(ConnectorJSON.self, from: request.httpBody!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        if input["id"] == nil { return (Data(), response) }
        let notification = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n".utf8)
        XCTAssertFalse(until?(notification, response) ?? true)
        let result: ConnectorJSON = input["method"]?.string == "initialize" ? .object(["protocolVersion": .string("2025-03-26")]) : .object(["tools": .array([.object(["name": .string("getJiraIssue")])])])
        let envelope = ConnectorJSON.object(["jsonrpc": .string("2.0"), "id": .string(mismatched ? "wrong-request-id" : input["id"]!.string!), "result": result])
        var bytes = notification
        // A multi-line data event, with a heartbeat preceding it.
        bytes.append(Data(": heartbeat\ndata: \(envelope.text.dropLast())\ndata: }\n\n".utf8))
        if mismatched { XCTAssertFalse(until?(bytes, response) ?? true) }
        else { XCTAssertTrue(until?(bytes, response) ?? false); stopped += 1 }
        return (bytes, response)
    }
}
