import Foundation

public enum DictationCleanup {
    public static func apply(_ text: String, replacements: [String: String], punctuation: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in replacements.keys.sorted(by: { $0.count > $1.count }) where !key.isEmpty {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: key) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: replacements[key]!))
        }
        if punctuation, !result.isEmpty {
            result = result.prefix(1).uppercased() + result.dropFirst()
            if result.last?.isLetter == true || result.last?.isNumber == true { result += "." }
        }
        return result
    }
    public static func vocabulary(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 50 else { throw PuddleError("Use up to 50 vocabulary replacements.") }
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[0].count <= 100, parts[1].count <= 200 else { throw PuddleError("Use one spoken phrase=written phrase per line.") }
            result[parts[0]] = parts[1]
        }
        return result
    }
}
