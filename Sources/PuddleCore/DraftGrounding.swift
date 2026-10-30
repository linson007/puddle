import Foundation

public enum DraftGrounding {
    /// Reject common unsupported first-person completion claims before replacing the editable draft.
    public static func validate(_ generated: String, userContext: String) throws {
        let pattern = #"\b(?:I|we)(?:['’](?:ve|d)|\s+(?:have|had|already))?\s+(?:already\s+)?(reviewed|checked|approved|sent|completed|attached|finished|verified)\b"#
        let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let supported = expression.matches(in: userContext, range: NSRange(userContext.startIndex..., in: userContext)).compactMap { match -> String? in
            guard let verb = Range(match.range(at: 1), in: userContext), let claim = Range(match.range, in: userContext) else { return nil }
            let prefix = userContext[..<claim.lowerBound].components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).last?.lowercased() ?? ""
            guard !["do not", "don't", "never", "whether", "if "].contains(where: { prefix.contains($0) }) else { return nil }
            return String(userContext[verb]).lowercased()
        }
        for match in expression.matches(in: generated, range: NSRange(generated.startIndex..., in: generated)) {
            guard let range = Range(match.range(at: 1), in: generated) else { continue }
            let verb = String(generated[range])
            guard supported.contains(verb.lowercased()) else {
                throw PuddleError("The model claimed work was already \(verb) without support in your instructions or draft. Your draft was kept. Clarify what is true, or write the reply directly.")
            }
        }
    }
}
