import Foundation
import PuddleCore

extension PuddleStore {
    func readRoutineTool(_ call: AgentToolCall, now: Date = Date()) async throws -> String {
        guard !privateSession, !isLocked else { throw CancellationError() }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
        func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        switch AgentTool(rawValue: call.function.name) {
        case .briefing: return state.executiveContext(now: now, mailConnected: mailConnected, calendarConnected: calendarConnected)
        case .tasks: return try encoded(state.tasks)
        case .memories:
            let query = String((arguments["query"] as? String ?? "").prefix(200))
            return try MemoryContext.encode(query: query, memories: state.memories)
        case .searchMail:
            guard mailConnected, !state.settings.networkDisabled else { throw PuddleError("Mail is not available for this routine.") }
            let query = String((arguments["query"] as? String ?? "").prefix(500))
            return SplashClient.emailContext(try await searchCurrentMail(query))
        case .knowledge:
            let query = String((arguments["query"] as? String ?? "").prefix(500))
            return try encoded(LocalKnowledge.search(query, documents: state.knowledgeDocuments))
        case .workContext:
            return workContext(String((arguments["query"] as? String ?? "").prefix(500)))
        case .calendar:
            guard calendarConnected, !state.settings.networkDisabled else { throw PuddleError("Calendar is not available for this routine.") }
            let days = max(1, min(14, arguments["days"] as? Int ?? 7))
            return try CalendarContext.encode(await GoogleCalendarClient(session: google, transport: transport).upcomingPage(days: days, now: Calendar.current.startOfDay(for: Date())))
        default: throw PuddleError("Routines can only read saved context, mail, and calendar. Actions and memory writes are unavailable.")
        }
    }
}
