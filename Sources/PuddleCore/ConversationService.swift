import Foundation

/// One turn shares discovery between learning and response generation.
public struct ConversationService: Sendable {
    public let connection: ModelConnection
    public init(connection: ModelConnection) { self.connection = connection }

    public func respond(question: String, history: [ChatLine], context: AgentContext, tools: [AgentTool],
                        contextTokens: Int = 8192,
                        learn: @Sendable ([MemoryUpdate]) async throws -> [MemoryNote],
                        execute: @Sendable (AgentToolCall) async throws -> String,
                        onActivity: @Sendable (String) async -> Void,
                        onPartial: @escaping @Sendable (String) async -> Void,
                        onMetrics: @Sendable (TurnMetrics) async -> Void = { _ in }) async throws -> String {
        let started = Date()
        var extractionSeconds = 0.0
        let timing = FirstTokenClock(started: started)
        let model = try await connection.model()
        let client = connection.client
        var context = context
        if context.memoryLearning, MemoryLearning.shouldLearn(question) {
            let extractionStart = Date()
            let updates: [MemoryUpdate]
            do { updates = try await MemoryLearner(splash: client).updates(from: question, memories: context.memories, model: model.id) }
            catch is CancellationError { throw CancellationError() }
            catch { updates = []; await onActivity("Memory extraction unavailable; continuing conversation") }
            try Task.checkCancellation()
            if !updates.isEmpty { context.memories = try await learn(updates) }
            extractionSeconds = Date().timeIntervalSince(extractionStart)
        }
        do {
            let answer = try await LocalAgent(splash: client).respond(question: question, history: history, context: context,
                tools: tools, execute: execute, onActivity: onActivity, model: model.id,
                contextTokens: min(contextTokens, model.contextTokens ?? contextTokens), onPartial: { text in
                    if !text.isEmpty { await timing.mark() }; await onPartial(text)
                })
            await onMetrics(TurnMetrics(totalSeconds: Date().timeIntervalSince(started), firstTokenSeconds: await timing.first,
                                        extractionSeconds: extractionSeconds))
            return answer
        } catch { await connection.invalidate(); throw error }
    }
}

private actor FirstTokenClock {
    let started: Date
    var first: Double?
    init(started: Date) { self.started = started }
    func mark() { if first == nil { first = Date().timeIntervalSince(started) } }
}

public enum PromptBudget {
    /// A conservative estimate for text; the server remains authoritative for its tokenizer.
    public static func tokens(_ text: String) -> Int {
        let bytes = text.utf8
        let ascii = bytes.reduce(0) { $0 + ($1 < 128 ? 1 : 0) }
        return (ascii + 2) / 3 + bytes.count - ascii
    }
    public static func tokens(messages: [AgentMessage], tools: [AgentTool]) -> Int {
        let schema = (try? JSONSerialization.data(withJSONObject: tools.map(\.definition))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return tokens(schema) + messages.reduce(0) { total, message in
            total + tokens(message.content) + 32 + (message.tool_calls ?? []).reduce(0) { $0 + tokens($1.function.arguments) + 32 }
        }
    }
}
