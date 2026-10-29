import Foundation

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

    func consume(_ line: String, onPartial: @Sendable (String) async -> Void) async throws {
        try Task.checkCancellation()
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix(":"), !line.hasPrefix("event:") else { return }
        let payload = line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
        if payload == "[DONE]" { return }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
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
            let call = calls[index]!
            guard !call.id.isEmpty, call.type == "function", !call.name.isEmpty else {
                throw PuddleError("The model's tool request was incomplete.")
            }
            return AgentToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }
        return AgentStep(content: content, calls: decoded, finishReason: finishReason)
    }
}
