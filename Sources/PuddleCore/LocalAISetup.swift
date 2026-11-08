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
        let answer = try await agentStep(messages: [AgentMessage(role: "user", content: "Say hello in one short sentence. This is a local connection test.")], tools: [], model: model.id, maxTokens: 100, onPartial: { _ in })
        guard !answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.calls.isEmpty,
              answer.finishReason != "length" else { throw PuddleError("The model connected but did not finish a simple reply. Check its configuration and retry.") }
        do {
            let question = AgentMessage(role: "user", content: "Call list_tasks exactly once with an empty object. Then summarize the synthetic tool result in one sentence.")
            let probe = try await agentStep(messages: [question], tools: [.tasks], model: model.id, requireToolCall: true, maxTokens: 150, onPartial: { _ in })
            var toolCalling = probe.finishReason != "length" && probe.calls.count == 1 && probe.calls[0].function.name == AgentTool.tasks.rawValue &&
                ((try? JSONSerialization.jsonObject(with: Data(probe.calls[0].function.arguments.utf8))) as? [String: Any])?.isEmpty == true
            if toolCalling {
                let followUp = try await agentStep(messages: [question,
                    AgentMessage(role: "assistant", content: probe.content, calls: probe.calls),
                    AgentMessage(role: "tool", content: "Synthetic setup fixture: no tasks. No personal workspace was read.", callID: probe.calls[0].id)],
                    tools: [], model: model.id, maxTokens: 150, onPartial: { _ in })
                toolCalling = followUp.calls.isEmpty && followUp.finishReason != "length" && !followUp.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
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
