import Foundation

extension AppSnapshot {
    public func matchingMemories(_ query: String) -> [MemoryNote] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return memories }
        var found: [MemoryNote] = []
        for note in memories {
            guard !Task.isCancelled else { break }
            if terms.allSatisfy({ term in note.title.localizedCaseInsensitiveContains(term) || note.content.localizedCaseInsensitiveContains(term) || note.source?.localizedCaseInsensitiveContains(term) == true }) { found.append(note) }
        }
        return found
    }
}

/// Keep tool replies valid and bounded even when years of memories are saved.
public enum MemoryContext {
    public static func encode(query: String, memories: [MemoryNote]) throws -> String {
        var snapshot = AppSnapshot(); snapshot.memories = memories
        let matches = snapshot.matchingMemories(String(query.prefix(500)))
        let selected = matches.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
        var items: [[String: Any]] = selected.map { ["id": $0.id.uuidString, "title": String($0.title.prefix(200)), "content": String($0.content.prefix(1200)), "content_truncated": $0.content.count > 1200] }
        func encoded() throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["format": "puddle-memory-context", "memories": items, "total_matches": matches.count, "has_more": items.count < matches.count, "scope": "Bounded saved memories matching this query. Narrow the query for omitted items. content_truncated marks excerpts; open Memory for complete facts."], options: [.sortedKeys]), as: UTF8.self)
        }
        var result = try encoded()
        while result.count > 10_000, !items.isEmpty { items.removeLast(); result = try encoded() }
        return result
    }
    static func fitting(_ text: String, characters: Int, tokens: Int) -> String? {
        guard let data = text.data(using: .utf8), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == "puddle-memory-context", var items = object["memories"] as? [[String: Any]] else { return nil }
        func encode() -> String {
            object["memories"] = items
            object["has_more"] = items.count < (object["total_matches"] as? Int ?? 0)
            return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        }
        var result = encode()
        while result.count > characters || PromptBudget.tokens(result) > tokens {
            if items.count > 1 { items.removeLast() }
            else if items.count == 1, let content = items[0]["content"] as? String, content.count > 32 {
                items[0]["content"] = String(content.prefix(content.count / 2)); items[0]["content_truncated"] = true
            } else if !items.isEmpty { items.removeAll() }
            else { return nil }
            result = encode()
        }
        return result
    }
}
