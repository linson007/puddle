import Foundation

public enum DraftGrounding {
    /// Common completion claims need support in the user's instructions or draft.
    public static func validate(_ generated: String, userContext: String) throws {
        let verbs = "reviewed|checked|approved|sent|completed|attached|finished|verified|enclosed|spoke|spoken|cc'd|copied"
        let patterns = [
            "\\b(?:I|we)(?:['’](?:ve|d)|\\s+(?:have|had|already))?\\s+(?:already\\s+)?(?:(?:gone|went)\\s+ahead\\s+and\\s+)?(" + verbs + ")\\b",
            "\\b(?:is|was|were|has\\s+been|have\\s+been|had\\s+been)\\s+(?:already\\s+)?(" + verbs + ")\\b",
            #"\b(?:please\s+)?find\s+(attached|enclosed)\b|\b(attached)\s+herewith\b|\b(enclosed)\s+(?:is|are)\b"#,
            #"\b(?:it|this|that)(?:['’]s|\s+is)\s+(all\s+set)\b"#,
        ]
        func claims(_ text: String, trusted: Bool) throws -> Set<String> {
            var claims = Set<String>()
            for pattern in patterns {
                let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let whole = Range(match.range, in: text) else { continue }
                    if trusted {
                        let prefix = text[..<whole.lowerBound].components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).last?.lowercased() ?? ""
                        let suffix = text[whole.upperBound...].prefix { !".!;\n".contains($0) }
                        if prefix.range(of: #"\b(?:not|never|whether|if|without|don't|don’t|haven't|hasn't|isn't)\b"#, options: .regularExpression) != nil || suffix.contains("?") { continue }
                    }
                    for group in 1..<match.numberOfRanges {
                        guard let range = Range(match.range(at: group), in: text) else { continue }
                        let verb = String(text[range]).lowercased()
                        let category: String
                        switch verb {
                        case "enclosed": category = "attached"
                        case "spoke": category = "spoken"
                        case "finished", "all set": category = "completed"
                        default: category = verb
                        }
                        claims.insert(category)
                    }
                }
            }
            return claims
        }
        let unsupported = try claims(generated, trusted: false).subtracting(claims(userContext, trusted: true))
        guard unsupported.isEmpty else {
            throw PuddleError("The model claimed completed work or an attachment without support in your instructions or draft. Your draft was kept. Clarify what is true, or write the reply directly.")
        }
    }
}
