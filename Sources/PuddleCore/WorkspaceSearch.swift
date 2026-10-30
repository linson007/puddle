import Foundation

public enum WorkspaceSearchKind: String, Sendable { case conversation, task, memory, meeting, email, event, action, project, person, decision, document, routine, errand }
public struct WorkspaceSearchResult: Identifiable, Sendable {
    public var id: String { kind.rawValue + ":" + locator }
    public let kind: WorkspaceSearchKind
    public let locator: String
    public let title: String
    public let preview: String
}
public enum WorkspaceSearch {
    public static func search(_ query: String, in snapshot: AppSnapshot) -> [WorkspaceSearchResult] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var results: [WorkspaceSearchResult] = []
        func scan<S: Sequence>(_ values: S, _ visit: (S.Element) -> Void) {
            for value in values {
                guard results.count < 80, !Task.isCancelled else { return }
                visit(value)
            }
        }
        func add(_ kind: WorkspaceSearchKind, _ id: String, _ title: String, _ fields: @autoclosure () -> [String]) {
            let fields = fields()
            guard words.allSatisfy({ word in !Task.isCancelled && (title.localizedCaseInsensitiveContains(word) || fields.contains { !Task.isCancelled && $0.localizedCaseInsensitiveContains(word) }) }) else { return }
            let text = fields.first { field in words.contains { field.localizedCaseInsensitiveContains($0) } } ?? fields.first ?? ""
            let match = words.lazy.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
            let begin = match.map { text.index($0.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
            results.append(WorkspaceSearchResult(kind: kind, locator: id, title: String(title.prefix(200)), preview: String(text[begin...].prefix(200))))
        }
        scan(snapshot.tasks) { add(.task, $0.id.uuidString, $0.title, [$0.owner, $0.notes]) }
        scan(snapshot.meetings) { add(.meeting, $0.id.uuidString, $0.title, [$0.notes, $0.transcript]) }
        let inbox = snapshot.settings.mailProvider == .outlook ? snapshot.outlookMessages : snapshot.messages
        scan(inbox) { add(.email, $0.id, $0.subject, [$0.sender, $0.body]) }
        scan(snapshot.calendarEvents) { add(.event, $0.id, $0.title, [$0.description, $0.location]) }
        scan(snapshot.memories) { add(.memory, $0.id.uuidString, $0.title, [$0.content]) }
        scan(snapshot.actionProposals) { add(.action, $0.id.uuidString, $0.title, [String(describing: $0.payload)]) }
        scan(snapshot.workProjects) { add(.project, $0.id.uuidString, $0.title, [$0.objective, $0.successCriteria]) }
        scan(snapshot.people) { add(.person, $0.id.uuidString, $0.name, [$0.email, $0.role, $0.promises, $0.talkingPoints, $0.notes]) }
        scan(snapshot.workDecisions) { add(.decision, $0.id.uuidString, $0.title, [$0.owner, $0.options, $0.rationale, $0.outcome]) }
        scan(snapshot.knowledgeDocuments) { add(.document, $0.id.uuidString, $0.name, [$0.text]) }
        scan(snapshot.routines) { add(.routine, $0.id.uuidString, $0.title, [$0.prompt]) }
        scan(snapshot.browserErrands) { add(.errand, $0.id.uuidString, $0.goal, [$0.latestProgress, $0.evidence ?? ""]) }
        if results.count < 80, !Task.isCancelled {
            scan(snapshot.conversationHistory) { add(.conversation, $0.id.uuidString, $0.title, $0.lines.map(\.content)) }
        }
        return results
    }
}
