import Foundation

public struct LocalAISetupVerification: Sendable {
    public let model: LocalInferenceModel
    public let answer: String
    public let toolCalling: Bool
    public let toolDiagnostic: String?
    public let checkedAt: Date
    public init(model: LocalInferenceModel, answer: String, toolCalling: Bool, checkedAt: Date = Date(), toolDiagnostic: String? = nil) {
        self.model = model; self.answer = answer; self.toolCalling = toolCalling; self.checkedAt = checkedAt; self.toolDiagnostic = toolDiagnostic
    }
}

extension LocalInferenceClient {
    /// Synthetic setup probes never retrieve personal data or execute an action.
    public func verifySetup() async throws -> LocalAISetupVerification {
        let model = try await modelInfo()
        let answer = try await agentStep(messages: [AgentMessage(role: "user", content: "Say hello in one short sentence. This is a local connection test.")], tools: [], model: model.id, maxTokens: 100)
        guard !answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.calls.isEmpty,
              answer.finishReason != "length" else { throw PuddleError("The model connected but did not finish a simple reply. Check its configuration and retry.") }
        do {
            let probe = try await agentStep(messages: [AgentMessage(role: "user", content: "Call list_tasks exactly once with an empty object. Do not answer in prose.")], tools: [.tasks], model: model.id, requireToolCall: true, maxTokens: 150)
            let toolCalling = probe.finishReason != "length" && probe.calls.count == 1 && probe.calls[0].function.name == AgentTool.tasks.rawValue &&
                ((try? JSONSerialization.jsonObject(with: Data(probe.calls[0].function.arguments.utf8))) as? [String: Any])?.isEmpty == true
            try Task.checkCancellation()
            return LocalAISetupVerification(model: model, answer: answer.content, toolCalling: toolCalling,
                toolDiagnostic: toolCalling ? nil : "Chat works. This model did not return the required tool call. Check its tool template or choose a tool-capable model.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return LocalAISetupVerification(model: model, answer: answer.content, toolCalling: false, toolDiagnostic: "Chat works; the tool probe failed: \(String(error.localizedDescription.prefix(500)))")
        }
    }
}
