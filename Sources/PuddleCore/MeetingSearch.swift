import Foundation

public struct MeetingSearchResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let field: String
    public let snippet: String
    public let hasUnsavedChanges: Bool
}

public enum MeetingSearch {
    public static func results(notes: [MeetingNote], drafts: [UUID: MeetingDraft] = [:], query: String) throws -> [MeetingSearchResult] {
        guard query.count <= 200 else { throw PuddleError("Use a search query up to 200 characters.") }
        let terms = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var results: [MeetingSearchResult] = []
        for note in notes.sorted(by: { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }) {
            try Task.checkCancellation()
            let draft = drafts[note.id] ?? MeetingDraft(note)
            var fields = [("Title", draft.title), ("Participants", draft.participants), ("Agenda", draft.agenda), ("Notes", draft.notes), ("Transcript", draft.transcript)]
            if let summary = note.summary {
                let label = summary.isCurrent(notes: draft.notes, transcript: draft.transcript) ? "Summary" : "Previous summary"
                fields.append((label, (summary.keyPoints + summary.decisions + summary.questions).map(\.quote).joined(separator: "\n")))
                fields.append((label == "Summary" ? "Action items" : "Previous action items", summary.actions.map { [$0.quote, $0.owner ?? "", $0.timing ?? ""].joined(separator: " ") }.joined(separator: "\n")))
            }
            let normalized = fields.map { normalize($0.1) }
            guard terms.allSatisfy({ term in normalized.contains { $0.contains(term) } }) else { continue }
            let index = normalized.firstIndex { field in terms.contains { field.contains($0) } } ?? 0
            let text = fields[index].1
            let match = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) }.first
            let start = match.map { text.index($0.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
            let snippet = String(text[start...].prefix(180)).replacingOccurrences(of: "\n", with: " ")
            results.append(MeetingSearchResult(id: note.id, title: draft.title, field: fields[index].0,
                snippet: (start == text.startIndex ? "" : "…") + snippet, hasUnsavedChanges: draft != MeetingDraft(note)))
        }
        return results
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
