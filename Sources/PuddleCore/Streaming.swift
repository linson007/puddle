import Foundation

struct CompletionStreamFinished: Error {}

/// Tool arguments are accumulated but never executed until a complete response arrives.
actor CompletionStream {
    struct PartialCall {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""
    }
    private var content = ""
    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var complete = false
    private var eventData: [String] = []
    private var eventBytes = 0
    private var eventType = ""

    func consume(_ line: String, onPartial: @Sendable (String) async -> Void) async throws {
        try Task.checkCancellation()
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty { try await dispatch(onPartial: onPartial); return }
        if line.hasPrefix(":") { return }
        // Some compatible servers return a complete JSON response instead of SSE.
        if eventData.isEmpty, line.hasPrefix("{") { try await payload(line, onPartial: onPartial); return }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(fields[0])
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { eventType = String(value.prefix(128)) }
        if field == "data" {
            eventBytes += value.utf8.count + 1
            guard eventBytes <= 256_000 else { throw PuddleError("The streaming response exceeded its event limit.") }
            eventData.append(value)
        }
    }

    func finish(onPartial: @Sendable (String) async -> Void) async throws {
        // EOF is not an SSE event delimiter. Never execute an unterminated tool event.
        guard eventData.isEmpty else { throw PuddleError("The model's response stream was incomplete. No pending tools were executed.") }
    }

    private func dispatch(onPartial: @Sendable (String) async -> Void) async throws {
        let data = eventData.joined(separator: "\n"), type = eventType
        eventData = []; eventBytes = 0; eventType = ""
        guard type != "error" else { throw PuddleError("The local model interrupted its response. Try again.") }
        guard !data.isEmpty else { return }
        try await payload(data, onPartial: onPartial)
    }

    private func payload(_ payload: String, onPartial: @Sendable (String) async -> Void) async throws {
        if payload == "[DONE]" {
            guard complete else { throw PuddleError("The model's response stream was incomplete. No pending tools were executed.") }
            throw CompletionStreamFinished()
        }
        let data = Data(payload.utf8)
        try JSONNesting.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PuddleError("The local model sent an invalid streaming event.")
        }
        if object["error"] != nil { throw PuddleError("The local model interrupted its response. Try again.") }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return } // usage or keepalive
        if let message = choice["message"] as? [String: Any] {
            // Compatibility with transports or servers returning a complete JSON response.
            content = message["content"] as? String ?? ""
            if let encoded = message["tool_calls"] {
                let decoded = try JSONDecoder().decode([AgentToolCall].self, from: JSONSerialization.data(withJSONObject: encoded))
                for (index, call) in decoded.enumerated() {
                    calls[index] = PartialCall(id: call.id, type: call.type, name: call.function.name, arguments: call.function.arguments)
                }
            }
        } else if let delta = choice["delta"] as? [String: Any] {
            content += delta["content"] as? String ?? ""
            for item in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = item["index"] as? Int, (0..<12).contains(index) else {
                    throw PuddleError("The model exceeded its streaming tool limit.")
                }
                var call = calls[index] ?? PartialCall()
                call.id += item["id"] as? String ?? ""
                if let type = item["type"] as? String { call.type = type }
                if let function = item["function"] as? [String: Any] {
                    call.name += function["name"] as? String ?? ""
                    call.arguments += function["arguments"] as? String ?? ""
                }
                guard call.arguments.utf8.count <= 32_000 else { throw PuddleError("Tool arguments exceeded their size limit.") }
                calls[index] = call
            }
        }
        guard content.utf8.count <= 128_000, calls.count <= 12 else { throw PuddleError("The response exceeded its size limit.") }
        if let reason = choice["finish_reason"] as? String { finishReason = reason; complete = true }
        if !content.isEmpty { await onPartial(content) }
    }

    func result() throws -> AgentStep {
        guard complete else { throw PuddleError("The model's response stream was incomplete. No pending tools were executed.") }
        let decoded = try calls.keys.sorted().map { index -> AgentToolCall in
            guard let call = calls[index] else { throw PuddleError("The model returned a missing tool call.") }
            guard !call.id.isEmpty, call.type == "function", !call.name.isEmpty else {
                throw PuddleError("The model's tool request was incomplete.")
            }
            return AgentToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }
        return AgentStep(content: content, calls: decoded, finishReason: finishReason)
    }
}
