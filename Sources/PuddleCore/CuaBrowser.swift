import Foundation

private struct CuaBrowserRefusal: LocalizedError {
    let tool: String
    let code: String
    let detail: String
    var errorDescription: String? { "Cua refused \(tool) (\(code)).\(detail) Check its permissions and current browser state before retrying." }
}

public struct CuaBrowserPage: Sendable {
    public let text: String
    public let summary: String
    public let processID: Int32
    public let elements: [String: String]
    public let actions: [String: Set<String>]
    public init(text: String, summary: String, processID: Int32, elements: [String: String] = [:], actions: [String: Set<String>] = [:]) {
        self.text = text; self.summary = summary; self.processID = processID; self.elements = elements
        self.actions = actions
    }
    /// Keep model refs explicit without putting a single long JSON line in chat.
    public var referenceText: String {
        let lines = elements.keys.sorted().prefix(20).map { ref in
            "\(ref) [\((actions[ref] ?? []).sorted().joined(separator: ", "))]: \(String((elements[ref] ?? "").prefix(120)))"
        }
        return "Current element refs (use these exact refs, never labels):\n" + lines.joined(separator: "\n") + "\n\nPage:\n" + String(summary.prefix(6000))
    }
}

public enum CuaBrowserAction: Sendable {
    case navigate(String)
    case click(String)
    case type(ref: String, text: String, replace: Bool)
    case scroll(ref: String, delta: Int)
}

public protocol CuaBrowserControlling: Sendable {
    func connect(executable: URL) async throws -> CuaBrowserPage
    func observe(tabID: String, query: String) async throws -> CuaBrowserPage
    func act(_ action: CuaBrowserAction) async throws -> CuaBrowserPage
    func disconnect() async
}

/// Browser-only adapter: no raw JavaScript, shell, desktop input, uploads or
/// attachment to personal browser profiles is exposed to the model.
public actor CuaBrowser: CuaBrowserControlling {
    private let factory: @Sendable (URL) -> any CuaRPCTransport
    private var transport: (any CuaRPCTransport)?
    private var session = ""
    private var targetID = ""
    private var tabID = ""
    private var processID: Int32 = 0
    private var windowID: Double = 0
    private var tabs: [ConnectorJSON] = []
    private var refs: [String: Set<String>] = [:]
    private var generation = UUID()
    private static let requiredTools: Set<String> = ["start_session", "end_session", "list_windows", "browser_prepare", "get_browser_state", "browser_navigate", "browser_click", "browser_type", "browser_pointer"]

    public init(factory: @escaping @Sendable (URL) -> any CuaRPCTransport = { CuaStdioTransport(executable: $0) }) {
        self.factory = factory
    }

    public func connect(executable: URL) async throws -> CuaBrowserPage {
        await disconnect()
        let expected = UUID(); generation = expected
        let connection = factory(executable)
        transport = connection; session = "puddle-\(UUID().uuidString)"
        do {
            let initialized = try await rpc("initialize", ["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Puddle"), "version": .string("0.1.0")])])
            guard initialized["protocolVersion"]?.string == "2025-06-18" else { throw PuddleError("Cua selected an unsupported MCP version. Update Cua Driver.") }
            _ = try await connection.rpc("notifications/initialized", parameters: .object([:]), notification: true)
            try check(expected)
            var names = Set<String>(), cursor: String?
            for _ in 0..<8 {
                let catalog = try await rpc("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:])
                names.formUnion(catalog["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
                guard let next = catalog["nextCursor"]?.string else { break }
                guard next != cursor else { throw PuddleError("Cua repeated its tool catalog cursor.") }; cursor = next
            }
            guard Self.requiredTools.isSubset(of: names) else { throw PuddleError("This Cua Driver does not support Puddle's browser tools. Install Cua Driver 0.38 or later.") }
            _ = try await call("start_session", [:])
            let prepared = try await call("browser_prepare", ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")])])
            guard let pid = prepared["prepared_pid"]?.number, pid > 0, pid <= Double(Int32.max), pid.rounded() == pid else {
                throw PuddleError("Cua did not return a dedicated browser process.")
            }
            processID = Int32(pid)
            for _ in 0..<30 {
                try check(expected)
                let windows = try await call("list_windows", ["pid": .number(pid)], withSession: false)
                for window in windows["windows"]?.array ?? [] {
                    guard let windowID = window["window_id"]?.number else { continue }
                    let binding: ConnectorJSON
                    do { binding = try await call("get_browser_state", ["pid": .number(pid), "window_id": .number(windowID)]) }
                    catch let refusal as CuaBrowserRefusal where refusal.code == "browser_wrong_target_refused" {
                        // Chrome's native window can appear before its CDP target.
                        // Retry this read-only exact binding; never weaken the match.
                        continue
                    }
                    try check(expected)
                    let activeTabs = (binding["tabs"]?.array ?? []).filter { $0["active"]?.bool == true }
                    guard binding["binding_quality"]?.string == "exact", binding["mutation_allowed"]?.bool == true,
                          let target = binding["target_id"]?.string, activeTabs.count == 1,
                          let tab = activeTabs.first?["tab_id"]?.string else { continue }
                    targetID = target; tabID = tab; self.windowID = windowID; tabs = binding["tabs"]?.array ?? []
                    return try await snapshot(query: "")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw PuddleError("Cua could not bind the dedicated browser window. Check Cua's macOS permissions and retry.")
        } catch {
            if generation == expected { await disconnect() }
            throw error
        }
    }

    public func observe(tabID requestedTab: String = "", query: String = "") async throws -> CuaBrowserPage {
        let expected = generation
        guard !targetID.isEmpty, !tabID.isEmpty, query.count <= 200 else { throw PuddleError("Start a browser session and use a page query under 200 characters.") }
        refs = [:]
        if requestedTab.isEmpty {
            // Refresh inventory explicitly and adopt both newly minted capabilities.
            // Never combine a new native binding with an earlier opaque tab ID.
            let binding = try await call("get_browser_state", ["pid": .number(Double(processID)), "window_id": .number(windowID)])
            try check(expected)
            let currentTabs = binding["tabs"]?.array ?? []
            let activeTabs = currentTabs.filter { $0["active"]?.bool == true }
            guard binding["binding_quality"]?.string == "exact", binding["mutation_allowed"]?.bool == true,
                  let target = binding["target_id"]?.string, activeTabs.count == 1, let active = activeTabs.first?["tab_id"]?.string else {
                throw PuddleError("Cua could not exactly identify the active tab. Read again or reconnect the dedicated browser.")
            }
            targetID = target; tabID = active; tabs = currentTabs
        } else {
            guard tabs.contains(where: { $0["tab_id"]?.string == requestedTab }) else { throw PuddleError("Choose a tab ID from this browser session's current tab list.") }
            tabID = requestedTab
        }
        return try await snapshot(query: query)
    }

    private func snapshot(query: String) async throws -> CuaBrowserPage {
        let expected = generation
        refs = [:]
        var args: [String: ConnectorJSON] = ["target_id": .string(targetID), "tab_id": .string(tabID), "snapshot_format": .string("semantic_v2"), "include_screenshot": .bool(false)]
        if !query.isEmpty { args["query"] = .string(query) }
        let state = try await call("get_browser_state", args)
        try check(expected)
        let entries = state["refs"]?.array ?? []
        var labels: [String: String] = [:]
        for entry in entries {
            if let ref = entry["ref"]?.string { refs[ref] = Set(entry["actions"]?.array?.compactMap(\.string) ?? []) }
            if let ref = entry["ref"]?.string { labels[ref] = String((entry["name"]?.string ?? entry["label"]?.string ?? ref).prefix(200)) }
        }
        let summary = state["outline"]?.string ?? state["snapshot"]?["outline"]?.string ?? state.text
        // Preserve complete JSON and current refs within a small text-model budget.
        let compactRefs = entries.prefix(20).map { entry -> ConnectorJSON in
            var value: [String: ConnectorJSON] = ["actions": .strings(entry["actions"]?.array?.compactMap(\.string) ?? [])]
            for key in ["ref", "name", "label", "role"] { if let text = entry[key]?.string { value[key] = .string(String(text.prefix(key == "ref" ? 200 : 120))) } }
            return .object(value)
        }
        var compact: [String: ConnectorJSON] = ["tab_id": .string(tabID), "outline": .string(String(summary.prefix(4000))),
            "refs": .array(compactRefs), "puddle_shortened": .bool(entries.count > 20 || summary.count > 4000),
            "tabs": .array(Array(tabs.prefix(30))),
            "scope": .string("Dedicated Cua browser. A snapshot may be incomplete; use a narrower query when needed.")]
        for key in ["title", "url", "snapshot", "continuation"] { if let value = state[key] { compact[key] = value } }
        let pageURL = state["page"]?["url"]?.string ?? state["url"]?.string
        if let pageURL {
            compact["page"] = .object(["url": .string(String(pageURL.prefix(2048))), "title": .string(String((state["page"]?["title"]?.string ?? state["title"]?.string ?? "").prefix(200)))])
        }
        let display = pageURL.map { String($0.prefix(2048)) + "\n" } ?? ""
        return CuaBrowserPage(text: ConnectorJSON.object(compact).text, summary: String((display + summary).prefix(16_000)), processID: processID, elements: labels, actions: refs)
    }

    public func act(_ action: CuaBrowserAction) async throws -> CuaBrowserPage {
        let expected = generation
        guard !targetID.isEmpty, !tabID.isEmpty else { throw PuddleError("Start a dedicated browser session first.") }
        var args: [String: ConnectorJSON] = ["target_id": .string(targetID), "tab_id": .string(tabID)]
        let tool: String
        switch action {
        case .navigate(let url):
            _ = try Self.navigationURL(url)
            tool = "browser_navigate"; args["url"] = .string(url)
        case .click(let ref):
            try require(ref, action: "click")
            tool = "browser_click"; args["ref"] = .string(ref); args["input_route"] = .string("dom_event")
        case .type(let ref, let text, let replace):
            try require(ref, action: "type")
            guard text.count <= 4000 else { throw PuddleError("Type at most 4,000 characters at once.") }
            tool = "browser_type"; args["ref"] = .string(ref); args["text"] = .string(text)
            args["replace"] = .bool(replace); args["mode"] = .string("insert_text")
        case .scroll(let ref, let delta):
            guard refs[ref]?.contains("scroll") == true || refs[ref]?.contains("pointer") == true,
                  delta != 0, (-2000...2000).contains(delta) else { throw PuddleError("Use a current scrollable ref and a nonzero scroll of at most 2,000 pixels.") }
            tool = "browser_pointer"; args["ref"] = .string(ref); args["action"] = .string("scroll")
            args["delta_y"] = .number(Double(delta)); args["input_route"] = .string("dom_event")
        }
        refs = [:]
        let result = try await call(tool, args)
        try check(expected)
        // Delivery is not proof: return fresh state after every action.
        do {
            let page = try await snapshot(query: "")
            return CuaBrowserPage(text: "Action result (verify the requested outcome):\n\(result.text)\nFresh page state:\n\(page.text)", summary: page.summary, processID: page.processID, elements: page.elements, actions: page.actions)
        } catch is CancellationError { throw CancellationError() }
        catch { throw PuddleError("The browser action was dispatched, but its result could not be observed. It may have happened. Read the page before repeating it.") }
    }

    public func disconnect() async {
        generation = UUID(); targetID = ""; tabID = ""; processID = 0; windowID = 0; tabs = []; refs = [:]
        let old = transport; transport = nil; session = ""
        if let old {
            // Closing this MCP transport releases its session-owned browser.
            // No shared daemon or personal browser process is terminated.
            // Cleanup must not delay Stop behind an in-flight RPC.
            await old.close()
        }
    }

    public static func navigationURL(_ raw: String) throws -> URL {
        guard raw.count <= 2048, !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw PuddleError("Use a complete http:// or https:// browser address without embedded credentials.")
        }
        return url
    }

    private func require(_ ref: String, action: String) throws {
        guard refs[ref]?.contains(action) == true else { throw PuddleError("Read the browser page again and use a current element ref supporting \(action).") }
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }
    private func rpc(_ method: String, _ args: [String: ConnectorJSON]) async throws -> ConnectorJSON {
        guard let transport else { throw PuddleError("The Cua browser is disconnected.") }
        let expected = generation
        let result = try await transport.rpc(method, parameters: .object(args), notification: false)
        try check(expected)
        return result
    }
    private func call(_ name: String, _ arguments: [String: ConnectorJSON], withSession: Bool = true) async throws -> ConnectorJSON {
        guard Self.requiredTools.contains(name) else { throw PuddleError("This operation is outside Puddle's browser tools.") }
        var args = arguments
        if withSession { args["session"] = .string(session) }
        let result = try await rpc("tools/call", ["name": .string(name), "arguments": .object(args)])
        let text = result["content"]?.array?.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n") ?? ""
        let value = result["structuredContent"] ?? (try? JSONDecoder().decode(ConnectorJSON.self, from: Data(text.utf8))) ?? .null
        guard result["isError"]?.bool != true, value["refusal"] == nil, value["status"]?.string != "refused" else {
            let problem = value["refusal"] ?? value["error"] ?? value
            let code = String((problem["code"]?.string ?? "request_refused").prefix(100))
            let reason = problem["message"]?.string ?? problem["reason"]?.string ?? problem.string
            let detail = reason.map { " " + String($0.prefix(400)) } ?? ""
            throw CuaBrowserRefusal(tool: name, code: code, detail: detail)
        }
        guard case .object = value else { throw PuddleError("Cua returned no structured browser state.") }
        return value
    }
}
