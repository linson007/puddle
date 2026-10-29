import Foundation

public enum SpeechText {
    /// Spoken replies omit code blocks, link destinations, and visual Markdown markers.
    public static func prepare(_ input: String, maximumCharacters: Int = 8000) -> String {
        var text = input.replacingOccurrences(of: #"(?s)```.*?(?:```|$)|~~~.*?(?:~~~|$)"#, with: " Code block omitted. ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://[^\s<>]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[`*_~]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(max(0, maximumCharacters)))
    }
}
