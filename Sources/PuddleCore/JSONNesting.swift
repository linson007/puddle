import Foundation

/// Check raw bytes before a recursive parser allocates nested containers.
enum JSONNesting {
    static let maximumDepth = 64
    static func validate(_ data: Data) throws {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= maximumDepth else { throw PuddleError("The JSON response exceeds its nesting limit.") }
            } else if byte == 93 || byte == 125 { depth -= 1 }
        }
    }
}
