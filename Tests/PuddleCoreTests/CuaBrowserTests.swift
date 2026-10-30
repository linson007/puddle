import Foundation
import XCTest
@testable import PuddleCore

private actor LiveBrowserRPCTrace: CuaRPCTransport {
    let base: CuaStdioTransport
    var bindings: [String] = []
    init(executable: URL) { base = CuaStdioTransport(executable: executable) }
    func close() async { await base.close() }
    func rpc(_ method: String, parameters: ConnectorJSON, notification: Bool) async throws -> ConnectorJSON {
        let result = try await base.rpc(method, parameters: parameters, notification: notification)
        if parameters["name"]?.string == "get_browser_state" {
            bindings.append(String(result.text.prefix(12_000)))
        }
        return result
    }
}

private actor BrowserRPCFixture: CuaRPCTransport {
    var calls: [(String, ConnectorJSON)] = []
    var closed = false
    var refused = false
    var missingTools = false
    var snapshot = 0
    var actionCount = 0
    var delayedRead = false
    var bindingRefusals = 0
    var bindingCount = 0
    var versionedBindings = false, secondTab = false
    func changeTabs() { secondTab = true }
    func useVersionedBindings() { versionedBindings = true }
    func configure(refused: Bool = false, missingTools: Bool = false, delayedRead: Bool = false, bindingRefusals: Int = 0) {
        self.refused = refused; self.missingTools = missingTools; self.delayedRead = delayedRead
        self.bindingRefusals = bindingRefusals
    }
    func close() async { closed = true }
    func rpc(_ method: String, parameters: ConnectorJSON, notification: Bool) async throws -> ConnectorJSON {
        guard !closed else { throw PuddleError("Fixture closed") }
        calls.append((method, parameters))
        if method == "initialize" { return .object(["protocolVersion": .string("2025-06-18")]) }
        if notification { return .null }
        if method == "tools/list" {
            let names = missingTools ? ["list_apps"] : ["start_session", "end_session", "list_windows", "browser_prepare", "get_browser_state", "browser_navigate", "browser_click", "browser_type", "browser_pointer"]
            return .object(["tools": .array(names.map { .object(["name": .string($0)]) })])
        }
        let name = parameters["name"]?.string ?? ""
        let args = parameters["arguments"]!
        let value: ConnectorJSON
        switch name {
        case "browser_prepare":
            if refused { return .object(["isError": .bool(true), "structuredContent": .object(["refusal": .object(["code": .string("accessibility_permission_missing")])])]) }
            value = .object(["status": .string("ok"), "prepared_pid": .number(1234)])
        case "list_windows": value = .object(["windows": .array([.object(["window_id": .number(42), "pid": .number(1234)])])])
        case "get_browser_state":
            if args["tab_id"] != nil {
                if delayedRead { try? await Task.sleep(for: .milliseconds(80)) }
                snapshot += 1
                let refs = ["click", "type", "scroll"].map { action in
                    ConnectorJSON.object(["ref": .string("s\(snapshot):\(action)"), "name": .string("Fixture \(action)"), "actions": .strings([action])])
                }
                value = .object(["status": .string("ok"), "outline": .string("Fixture browser page \(snapshot)"), "refs": .array(refs)])
            } else {
                bindingCount += 1
                if bindingRefusals > 0 {
                    bindingRefusals -= 1
                    return .object(["structuredContent": .object(["status": .string("refused"), "refusal": .object(["code": .string("browser_wrong_target_refused")])])])
                }
                let suffix = versionedBindings ? "-\(bindingCount)" : ""
                var tabs: [ConnectorJSON] = [.object(["active": .bool(!secondTab), "tab_id": .string("owned-tab" + suffix)])]
                if secondTab { tabs.append(.object(["active": .bool(true), "tab_id": .string("owned-tab" + suffix + "-second")])) }
                value = .object(["status": .string("ok"), "binding_quality": .string("exact"), "mutation_allowed": .bool(true), "target_id": .string("owned-target" + suffix), "tabs": .array(tabs)])
            }
        case "browser_navigate", "browser_click", "browser_type", "browser_pointer":
            actionCount += 1; value = .object(["status": .string("ok"), "effect": .string("unverifiable")])
        default: value = .object(["status": .string("ok")])
        }
        return .object(["structuredContent": value, "content": .array([])])
    }
}

final class CuaBrowserTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/fixture/cua-driver")

    func testDedicatedSessionUsesOneConnectionAndOnlyScopedBrowserCalls() async throws {
        let rpc = BrowserRPCFixture(), browser = CuaBrowser(factory: { _ in rpc })
        let page = try await browser.connect(executable: executable)
        XCTAssertEqual(page.processID, 1234); XCTAssertTrue(page.text.contains("Fixture browser page"))
        _ = try await browser.act(.navigate("https://example.test/"))
        let calls = await rpc.calls
        let tools = calls.filter { $0.0 == "tools/call" }
        let prepared = try XCTUnwrap(tools.first { $0.1["name"]?.string == "browser_prepare" }?.1["arguments"])
        XCTAssertEqual(prepared["profile"]?["mode"]?.string, "isolated_new")
        XCTAssertEqual(prepared["allow_launch"]?.bool, true)
        let session = try XCTUnwrap(prepared["session"]?.string)
        XCTAssertTrue(session.hasPrefix("puddle-"))
        for tool in tools where tool.1["name"]?.string != "list_windows" {
            XCTAssertEqual(tool.1["arguments"]?["session"]?.string, session)
        }
        XCTAssertFalse(tools.contains { ["run_script", "page", "launch_app", "browser_set_input_files"].contains($0.1["name"]?.string ?? "") })
        let navigation = try XCTUnwrap(tools.first { $0.1["name"]?.string == "browser_navigate" }?.1["arguments"])
        XCTAssertEqual(navigation["target_id"]?.string, "owned-target"); XCTAssertEqual(navigation["tab_id"]?.string, "owned-tab")
        await browser.disconnect()
        let closed = await rpc.closed; XCTAssertTrue(closed)
    }

    func testActionsRequireFreshRefsAndReturnObservedState() async throws {
        let rpc = BrowserRPCFixture(), browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable)
        let result = try await browser.act(.click("s1:click"))
        XCTAssertTrue(result.text.contains("unverifiable")); XCTAssertTrue(result.text.contains("Fixture browser page 2"))
        do { _ = try await browser.act(.click("s1:click")); XCTFail("Stale ref accepted") } catch {}
        do { _ = try await browser.act(.type(ref: "s2:click", text: "wrong action", replace: true)); XCTFail("Wrong action accepted") } catch {}
        _ = try await browser.act(.type(ref: "s2:type", text: "  keep spaces\n", replace: true))
        let args = await rpc.calls.last { $0.1["name"]?.string == "browser_type" }?.1["arguments"]
        XCTAssertEqual(args?["text"]?.string, "  keep spaces\n")
        XCTAssertEqual(args?["replace"]?.bool, true)
        let count = await rpc.actionCount; XCTAssertEqual(count, 2)
    }

    func testRepeatedObservationsKeepTheOriginalOpaqueBinding() async throws {
        let rpc = BrowserRPCFixture(), browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable)
        _ = try await browser.observe(tabID: "owned-tab", query: "Fixture")
        _ = try await browser.act(.click("s2:click"))
        let bindings = await rpc.calls.filter { $0.1["name"]?.string == "get_browser_state" && $0.1["arguments"]?["pid"] != nil }
        XCTAssertEqual(bindings.count, 1, "Native rebinding remints opaque tab IDs; keep the original capability for scoped reads/actions")
        await browser.disconnect()
    }
    func testActiveReadRefreshesTabsAndAdoptsMatchingOpaqueCapabilities() async throws {
        let rpc = BrowserRPCFixture(); await rpc.useVersionedBindings()
        let browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable)
        await rpc.changeTabs()
        let page = try await browser.observe(tabID: "", query: "")
        XCTAssertTrue(page.text.contains("owned-tab-2-second"))
        _ = try await browser.observe(tabID: "owned-tab-2-second", query: "")
        do { _ = try await browser.observe(tabID: "owned-tab-1", query: ""); XCTFail("Old tab capability accepted") } catch {}
        _ = try await browser.act(.navigate("https://example.test/"))
        let navigation = await rpc.calls.last { $0.1["name"]?.string == "browser_navigate" }?.1["arguments"]
        XCTAssertEqual(navigation?["target_id"]?.string, "owned-target-2")
        XCTAssertEqual(navigation?["tab_id"]?.string, "owned-tab-2-second")
        await browser.disconnect()
    }
    func testErrandReferencesAreBoundedReadableAndKeepExactActionRefs() {
        let page = CuaBrowserPage(text: String(repeating: "{long-json}", count: 2000), summary: String(repeating: "page\n", count: 2000), processID: 1,
                                  elements: ["p23:4": "Test note"], actions: ["p23:4": ["type"]])
        XCTAssertTrue(page.referenceText.contains("p23:4 [type]: Test note"))
        XCTAssertFalse(page.referenceText.contains("long-json"))
        XCTAssertLessThan(page.referenceText.count, 6500)
    }

    func testStartupWaitsForExactCDPBindingWithoutReplayingActions() async throws {
        let rpc = BrowserRPCFixture(); await rpc.configure(bindingRefusals: 1)
        let browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable)
        let bindings = await rpc.calls.filter { $0.1["name"]?.string == "get_browser_state" && $0.1["arguments"]?["pid"] != nil }
        XCTAssertEqual(bindings.count, 2)
        let count = await rpc.actionCount; XCTAssertEqual(count, 0)
        await browser.disconnect()
    }

    func testUnknownTabsAndUnsafeNavigationNeverDispatch() async throws {
        let rpc = BrowserRPCFixture(), browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable)
        do { _ = try await browser.observe(tabID: "another-session", query: ""); XCTFail("Unknown tab accepted") } catch {}
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.test/", "https://example.test/with space"] {
            do { _ = try await browser.act(.navigate(url)); XCTFail("Unsafe URL accepted") } catch {}
        }
        let count = await rpc.actionCount; XCTAssertEqual(count, 0)
        XCTAssertNoThrow(try CuaBrowser.navigationURL("http://127.0.0.1:8000/fixture"))
    }

    func testMissingCapabilityOrPermissionClosesFailedConnection() async throws {
        for missingTools in [false, true] {
            let rpc = BrowserRPCFixture(); await rpc.configure(refused: !missingTools, missingTools: missingTools)
            let browser = CuaBrowser(factory: { _ in rpc })
            do { _ = try await browser.connect(executable: executable); XCTFail("Expected unavailable browser") } catch {}
            let closed = await rpc.closed; XCTAssertTrue(closed)
            let count = await rpc.actionCount; XCTAssertEqual(count, 0)
        }
    }

    func testDisconnectRejectsLateSnapshot() async throws {
        let rpc = BrowserRPCFixture(), browser = CuaBrowser(factory: { _ in rpc })
        _ = try await browser.connect(executable: executable); await rpc.configure(delayedRead: true)
        let read = Task { try await browser.observe(tabID: "", query: "") }
        try await Task.sleep(for: .milliseconds(10)); await browser.disconnect()
        do { _ = try await read.value; XCTFail("Late page published") } catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    }

    private func script(_ behavior: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-cua-rpc-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cua-driver")
        let source = """
        #!/usr/bin/python3
        import json, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            \(behavior)
        """
        try Data(source.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func testStdioMCPHandlesNotificationsAndMatchesRequestIDs() async throws {
        let file = try script("print(json.dumps({'jsonrpc':'2.0','method':'notifications/progress'}), flush=True)\n    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'method':request['method']}}), flush=True)")
        let transport = CuaStdioTransport(executable: file)
        let reply = try await transport.rpc("initialize", parameters: .object([:]))
        XCTAssertEqual(reply["method"]?.string, "initialize")
        _ = try await transport.rpc("notifications/initialized", parameters: .object([:]), notification: true)
        let second = try await transport.rpc("tools/list", parameters: .object([:]))
        XCTAssertEqual(second["method"]?.string, "tools/list")
        await transport.close()
    }

    func testStdioMCPTimeoutAndCancellationStopWithoutReplay() async throws {
        let file = try script("time.sleep(10)")
        let transport = CuaStdioTransport(executable: file, timeout: 0.1)
        do { _ = try await transport.rpc("tools/call", parameters: .object([:])); XCTFail("Expected timeout") } catch {}
        let cancelled = CuaStdioTransport(executable: file)
        let request = Task { try await cancelled.rpc("tools/call", parameters: .object([:])) }
        try await Task.sleep(for: .milliseconds(50)); request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") } catch {}
        do { _ = try await cancelled.rpc("tools/call", parameters: .object([:])); XCTFail("Closed connection replayed") } catch {}
    }

    func testInstalledDriverMCPHandshakeAndBrowserCatalog() async throws {
        guard let path = ProcessInfo.processInfo.environment["PUDDLE_CUA_DRIVER"] else {
            throw XCTSkip("Set PUDDLE_CUA_DRIVER to an installed Cua Driver for the optional real MCP check")
        }
        let transport = CuaStdioTransport(executable: URL(fileURLWithPath: path))
        let initialized = try await transport.rpc("initialize", parameters: .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Puddle test"), "version": .string("0.1.0")])]))
        XCTAssertEqual(initialized["protocolVersion"]?.string, "2025-06-18")
        _ = try await transport.rpc("notifications/initialized", parameters: .object([:]), notification: true)
        let catalog = try await transport.rpc("tools/list", parameters: .object([:]))
        let names = Set(catalog["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
        XCTAssertTrue(Set(["browser_prepare", "get_browser_state", "browser_click", "browser_type"]).isSubset(of: names))
        await transport.close()
        if ProcessInfo.processInfo.environment["PUDDLE_CUA_LIVE"] == "1" {
            let trace = LiveBrowserRPCTrace(executable: URL(fileURLWithPath: path))
            let browser = CuaBrowser(factory: { _ in trace })
            do {
                let page = try await browser.connect(executable: URL(fileURLWithPath: path))
                XCTAssertGreaterThan(page.processID, 0)
                _ = try await browser.observe(tabID: "", query: "")
                if let localPage = ProcessInfo.processInfo.environment["PUDDLE_CUA_LIVE_URL"] {
                    let url = try CuaBrowser.navigationURL(localPage)
                    guard url.host == "127.0.0.1" else { throw PuddleError("Live fixture checks require an IPv4 loopback URL.") }
                    let observed = try await browser.act(.navigate(localPage))
                    XCTAssertTrue(observed.summary.contains(url.absoluteString))
                    XCTAssertTrue(observed.summary.contains("Puddle local browser acceptance"))
                }
                await browser.disconnect()
            } catch {
                let bindings = await trace.bindings
                await browser.disconnect()
                XCTFail("Live dedicated browser failed: \(error). Bindings: \(bindings)")
            }
        }
    }
}
