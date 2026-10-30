import Foundation

struct AtlassianToolResult: Sendable {
    let value: ConnectorJSON
    let text: String
}
actor AtlassianMCP {
    static let permittedTools: Set<String> = ["getAccessibleAtlassianResources", "atlassianUserInfo", "searchJiraIssuesUsingJql", "getJiraIssue", "searchConfluence", "getConfluenceContent"]
    private let transport: any HTTPTransport
    private let authorization: @Sendable () async throws -> String
    private var sessionID: String?
    private var protocolVersion = "2025-03-26"
    private var initialized = false
    private var initialization: Task<Void, Error>?
    init(transport: any HTTPTransport, authorization: @escaping @Sendable () async throws -> String) { self.transport = transport; self.authorization = authorization }
    private nonisolated static func events(_ data: Data) throws -> [ConnectorJSON] {
        var events: [ConnectorJSON] = [], lines: [String] = []
        for line in String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty {
                if !lines.isEmpty { events.append(try WorkConnectorHTTP.decode(Data(lines.joined(separator: "\n").utf8))); lines = [] }
            } else if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        return events
    }
    private func rpc(_ method: String, parameters: ConnectorJSON, notification: Bool = false) async throws -> ConnectorJSON {
        let id = UUID().uuidString
        var body: [String: ConnectorJSON] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": parameters]
        if !notification { body["id"] = .string(id) }
        var request = URLRequest(url: AtlassianAuthorization.resource, timeoutInterval: 45); request.httpMethod = "POST"
        request.setValue("Bearer \(try await authorization())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if initialized { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = ConnectorJSON.object(body).data
        let (data, response) = try await WorkConnectorHTTP.send(request, transport: transport, service: "Atlassian", hosts: ["mcp.atlassian.com"], until: { data, response in
            guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true,
                  data.suffix(2) == Data("\n\n".utf8) || data.suffix(4) == Data("\r\n\r\n".utf8) else { return false }
            return (try? Self.events(data).contains { $0["id"]?.string == id }) == true
        })
        if notification { return .null }
        if let header = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard !header.isEmpty, header.count <= 512, !header.contains(where: { $0.isNewline }) else { throw PuddleError("Atlassian returned an invalid MCP session.") }
            sessionID = header
        }
        let envelopes: [ConnectorJSON]
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            envelopes = try Self.events(data)
        } else { envelopes = [try WorkConnectorHTTP.decode(data)] }
        guard let envelope = envelopes.first(where: { $0["id"]?.string == id }), envelope["jsonrpc"]?.string == "2.0" else { throw PuddleError("Atlassian returned an unmatched MCP response.") }
        guard envelope["error"] == nil, let result = envelope["result"] else { throw PuddleError("Atlassian could not complete this read. Check the query, permissions, or connection.") }
        return result
    }
    private func initialize() async throws {
        if let initialization { try await initialization.value; return }
        guard !initialized else { return }
        let worker = Task { [self] in
          do {
            let result = try await rpc("initialize", parameters: .object(["protocolVersion": .string(protocolVersion), "capabilities": .object([:]), "clientInfo": .object(["name": .string("Puddle"), "version": .string("0.1.0")])]))
            guard let version = result["protocolVersion"]?.string, ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw PuddleError("Atlassian selected an unsupported MCP protocol version.") }
            protocolVersion = version; initialized = true
            _ = try await rpc("notifications/initialized", parameters: .object([:]), notification: true)
          } catch { initialized = false; sessionID = nil; throw error }
        }
        initialization = worker
        defer { initialization = nil }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private func readRPC(_ method: String, parameters: ConnectorJSON) async throws -> ConnectorJSON {
        do { return try await rpc(method, parameters: parameters) }
        catch let error as HTTPServiceError where error.statusCode == 404 && sessionID != nil {
            // Streamable HTTP servers may expire an idle session. Replay only our read operations once.
            sessionID = nil; initialized = false
            try await initialize()
            return try await rpc(method, parameters: parameters)
        }
    }
    func tools() async throws -> Set<String> {
        try await initialize()
        var names = Set<String>(), cursor: String?
        for _ in 0..<4 {
            let result = try await readRPC("tools/list", parameters: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
            guard let tools = result["tools"]?.array else { throw PuddleError("Atlassian did not return a tool catalog.") }
            names.formUnion(tools.compactMap { $0["name"]?.string })
            guard let next = result["nextCursor"]?.string else { return names }
            guard cursor != next else { throw PuddleError("Atlassian repeated its tool cursor.") }; cursor = next
        }
        return names
    }
    func call(_ name: String, arguments: [String: ConnectorJSON]) async throws -> AtlassianToolResult {
        guard Self.permittedTools.contains(name) else { throw PuddleError("This Atlassian operation is outside Puddle's read-only connector.") }
        try await initialize()
        let result = try await readRPC("tools/call", parameters: .object(["name": .string(name), "arguments": .object(arguments)]))
        guard result["isError"]?.bool != true else { throw PuddleError("Atlassian could not complete this read. Check query syntax, resource access and selected site.") }
        let texts = result["content"]?.array?.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil } ?? []
        if let structured = result["structuredContent"] { return AtlassianToolResult(value: structured, text: structured.text) }
        for text in texts { if let value = try? WorkConnectorHTTP.decode(Data(text.utf8)) { return AtlassianToolResult(value: value, text: text) } }
        let text = texts.joined(separator: "\n")
        guard !text.isEmpty else { throw PuddleError("Atlassian returned no readable content.") }
        return AtlassianToolResult(value: .string(text), text: text)
    }
}
