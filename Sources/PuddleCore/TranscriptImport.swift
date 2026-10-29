import Foundation

public enum TranscriptFileFormat: String, Sendable {
    case text, webVTT, subRip
    public var title: String { switch self { case .text: "Text"; case .webVTT: "WebVTT"; case .subRip: "SubRip" } }
}

public struct ImportedTranscript: Sendable, Equatable {
    public let text: String
    public let sourceName: String
    public let format: TranscriptFileFormat
    public let cueCount: Int
    public init(text: String, sourceName: String, format: TranscriptFileFormat = .text, cueCount: Int = 0) {
        self.text = text; self.sourceName = sourceName; self.format = format; self.cueCount = cueCount
    }
}

public enum TranscriptImport {
    public static let maximumBytes = 2_000_000
    public static let maximumCharacters = 200_000

    public static func read(from url: URL) throws -> ImportedTranscript {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PuddleError("Choose a regular transcript file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }; data.append(chunk)
        }
        return try decode(data, filename: url.lastPathComponent)
    }

    public static func decode(_ data: Data, filename: String) throws -> ImportedTranscript {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw PuddleError("Transcript imports are limited to 2 MB. Split this file before importing.") }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ["txt", "md", "vtt", "srt"].contains(ext) else { throw PuddleError("Choose a .txt, .md, .vtt, or .srt transcript.") }
        let decoded: String?
        if data.starts(with: [0xFF, 0xFE]) { decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { decoded = String(data: data, encoding: .utf8) }
        guard var text = decoded, !text.contains("\0") else { throw PuddleError("The transcript is not readable UTF-8 or UTF-16 text.") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let format: TranscriptFileFormat = ext == "vtt" ? .webVTT : ext == "srt" ? .subRip : .text
        var cueCount = 0
        if format != .text {
            text = text.replacingOccurrences(of: #"(?m)^[\t ]+$"#, with: "", options: .regularExpression)
            var cues: [String] = []
            for block in text.components(separatedBy: "\n\n") {
                try Task.checkCancellation()
                let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if let first = lines.first, first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
                guard let timing = lines.firstIndex(where: { $0.contains("-->") }), timing + 1 < lines.count else { continue }
                let stamp = lines[timing].components(separatedBy: "-->")[0].trimmingCharacters(in: .whitespaces)
                guard stamp.range(of: #"^(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}$"#, options: .regularExpression) != nil else { continue }
                var body = lines.dropFirst(timing + 1).joined(separator: " ")
                body = body.replacingOccurrences(of: #"<v\s+([^>]+)>"#, with: "$1: ", options: .regularExpression)
                body = MailText.decodeEntities(body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                cues.append("[\(stamp.replacingOccurrences(of: ",", with: "."))] \(body)"); cueCount += 1
            }
            guard !cues.isEmpty else { throw PuddleError("No readable subtitle cues were found in this transcript.") }
            text = cues.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PuddleError("The transcript file is empty.") }
        guard text.count <= maximumCharacters else { throw PuddleError("The transcript exceeds 200,000 characters. Split it before importing; no text was truncated.") }
        return ImportedTranscript(text: text, sourceName: String((filename as NSString).lastPathComponent.prefix(200)), format: format, cueCount: cueCount)
    }
}
