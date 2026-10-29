import Foundation

public enum MeetingExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, text, json, transcript
    public var id: Self { self }
    public var title: String {
        switch self { case .markdown: "Markdown"; case .text: "Plain text"; case .json: "JSON"; case .transcript: "Transcript only" }
    }
    public var fileExtension: String { self == .markdown ? "md" : self == .json ? "json" : "txt" }
}

public struct MeetingExportDocument: Codable, Sendable {
    public let exportVersion: Int
    public let exportedAt: Date
    public let includesUnsavedEdits: Bool
    public let includesFullTranscript: Bool
    public let includesJoinLink: Bool
    public let summarySourceStatus: String
    public let note: MeetingNote
}

public enum MeetingExport {
    public static func data(note: MeetingNote, draft: MeetingDraft? = nil, format: MeetingExportFormat,
                            includeTranscript: Bool = true, includeJoinLink: Bool = false, now: Date = Date()) throws -> Data {
        let draft = draft ?? MeetingDraft(note)
        var effective = try draft.applying(to: note, now: note.updatedAt)
        if format == .transcript { return Data(effective.transcript.utf8) }
        let status = effective.summary.map { $0.isCurrent(notes: effective.notes, transcript: effective.transcript) ? "current" : "out of date" } ?? "not generated"
        if !includeTranscript { effective.transcript = "" }
        if !includeJoinLink { effective.joinLink = nil }
        let unsaved = draft != MeetingDraft(note)
        if format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(MeetingExportDocument(exportVersion: 1, exportedAt: now, includesUnsavedEdits: unsaved,
                includesFullTranscript: includeTranscript, includesJoinLink: includeJoinLink, summarySourceStatus: status, note: effective))
        }
        let markdown = format == .markdown
        func plain(_ value: String) -> String { markdown ? escape(value) : value }
        var lines = [markdown ? "# \(plain(effective.title))" : effective.title,
                     "", "Meeting date: \(effective.meetingDate.ISO8601Format())", "Exported: \(now.ISO8601Format())"]
        if unsaved { lines.append("Includes unsaved edits from the current draft.") }
        func section(_ title: String, _ text: String) {
            guard !text.isEmpty else { return }
            lines += ["", markdown ? "## \(title)" : title, "", plain(text)]
        }
        section("Participants", effective.participants); section("Agenda", effective.agenda); section("Notes", effective.notes)
        if let summary = effective.summary {
            section("AI-selected meeting extracts", "Source status: \(status). Review classification against the original text. Generated \(summary.generatedAt.ISO8601Format()) using \(summary.model).")
            func excerpts(_ title: String, _ items: [MeetingExcerpt]) { section(title, items.map { "• \($0.quote)" }.joined(separator: "\n\n")) }
            excerpts("Key points", summary.keyPoints); excerpts("Decisions", summary.decisions)
            section("Action items", summary.actions.map { item in
                "• \(item.quote)\nOwner: \(item.owner ?? "Not stated")\nTiming: \(item.timing ?? "Not stated")" + (item.taskID.map { "\nLocal task ID: \($0.uuidString)" } ?? "")
            }.joined(separator: "\n\n"))
            excerpts("Open questions", summary.questions)
        }
        if includeTranscript, !effective.transcript.isEmpty {
            lines += ["", markdown ? "## Transcript" : "Transcript", ""]
            if markdown {
                let longest = effective.transcript.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                lines += [fence + "text", effective.transcript, fence]
            } else { lines.append(effective.transcript) }
        }
        if let link = effective.joinLink { section("Join link", link.url.absoluteString) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func filename(title: String, format: MeetingExportFormat) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let trimmed = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let name = String(trimmed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (name.isEmpty ? "Meeting notes" : name) + "." + format.fileExtension
    }

    public static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw PuddleError("Choose a local file destination for the export.") }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func escape(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_{}[]<>()#+.!|>~-".contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }
}
