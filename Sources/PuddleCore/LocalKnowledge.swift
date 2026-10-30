import Foundation
import CryptoKit
import PDFKit

public struct KnowledgeSource: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var bookmark: Data
    public var indexedAt: Date?
    public var status = "Not indexed yet"
    public init(url: URL) throws {
        name = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            let error = error as NSError
            throw PuddleError("Could not retain read access to \(name): \(error.localizedDescription) (\(error.domain) \(error.code)). Choose the source again.")
        }
    }
    public func url() throws -> URL {
        var stale = false
        let value = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw PuddleError("Choose this source again to renew its folder access.") }
        return value
    }
}
public struct KnowledgeDocument: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let sourceID: UUID
    public let name: String
    public let url: URL
    public let modifiedAt: Date
    public let bytes: Int
    public let sha256: String
    public let text: String
    public let limited: Bool
    public init(sourceID: UUID, name: String, url: URL, modifiedAt: Date, bytes: Int, text: String, limited: Bool) {
        self.sourceID = sourceID; self.name = name; self.url = url; self.modifiedAt = modifiedAt; self.bytes = bytes
        self.text = text; self.limited = limited; sha256 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct KnowledgePassage: Codable, Identifiable, Sendable {
    public var id: String { documentID.uuidString + ":" + String(line) }
    public let documentID: UUID
    public let title: String
    public let url: URL
    public let line: Int
    public let quote: String
    public let limited: Bool
}
public enum LocalKnowledge {
    public static let extensions: Set<String> = ["txt", "md", "csv", "tsv", "json", "log", "html", "xml", "pdf", "docx"]
    public static func refresh(_ source: KnowledgeSource, previous: [KnowledgeDocument]) throws -> (KnowledgeSource, [KnowledgeDocument]) {
        let root = try source.url(), scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let files = try KnowledgeFiles(root: root), inventory = try files.inventory()
        var incomplete = inventory.incomplete
        var documents: [KnowledgeDocument] = [], errors = 0, characterBudget = 10_000_000
        for path in inventory.paths.sorted() {
            try Task.checkCancellation()
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            do {
                // Validate and capture even on cache hits: never trust metadata on
                // a pathname that may have been replaced since enumeration.
                let captured = try files.capture(path, maximumBytes: byteLimit(url.pathExtension))
                if let unchanged = previous.first(where: { $0.url == url && $0.modifiedAt == captured.modifiedAt && $0.bytes == captured.bytes }) {
                    guard unchanged.text.count <= characterBudget else { incomplete = true; break }
                    documents.append(unchanged); characterBudget -= unchanged.text.count; continue
                }
                let (text, limited) = try extract(captured.data, kind: url.pathExtension.lowercased())
                guard text.count <= characterBudget else { incomplete = true; break }
                var document = KnowledgeDocument(sourceID: source.id, name: url.lastPathComponent, url: url, modifiedAt: captured.modifiedAt, bytes: captured.bytes, text: text, limited: limited)
                if let old = previous.first(where: { $0.url == url }) { document.id = old.id }
                documents.append(document); characterBudget -= text.count
            } catch is CancellationError { throw CancellationError() }
            catch { errors += 1 }
        }
        var updated = source; updated.indexedAt = Date()
        updated.status = "\(documents.count) indexed · \(errors) unreadable\(incomplete ? " · Incomplete scan; choose a smaller folder" : "")"
        return (updated, documents)
    }
    public static func extract(_ url: URL) throws -> (String, Bool) {
        let files = try KnowledgeFiles(root: url)
        guard !files.isDirectory else { throw PuddleError("Choose a regular document file.") }
        return try extract(files.capture("", maximumBytes: byteLimit(url.pathExtension)).data, kind: url.pathExtension.lowercased())
    }
    private static func byteLimit(_ kind: String) -> Int { ["pdf", "docx"].contains(kind.lowercased()) ? 25 * 1024 * 1024 : 2 * 1024 * 1024 }
    static func extract(_ data: Data, kind: String) throws -> (String, Bool) {
        guard extensions.contains(kind), data.count <= byteLimit(kind) else { throw PuddleError("Choose supported text under 2 MB, or a PDF/DOCX under 25 MB.") }
        let maximum = 200_000
        var text: String
        var limited = false
        if kind == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw PuddleError("Unlock this PDF before importing it.") }
            text = ""; limited = document.pageCount > 200; var hasText = false
            for page in 0..<min(200, document.pageCount) {
                try Task.checkCancellation(); let passage = document.page(at: page)?.string ?? ""
                hasText = hasText || !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                text += "[Page \(page + 1)]\n" + passage + "\n\n"
                if text.count > maximum { limited = true; break }
            }
            guard hasText else { throw PuddleError("This PDF has no selectable text. OCR is not available in this importer.") }
        } else if kind == "docx" {
            let xml = try OfficeDocumentRead.documentXML(data)
            text = try OfficeDocumentRead.text(xml)
        } else {
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw PuddleError("The document text encoding is unsupported.") }
            text = kind == "html" ? MailText.fromHTML(decoded) : decoded
        }
        limited = limited || text.count > maximum
        return (String(text.prefix(maximum)), limited)
    }
    public static func search(_ query: String, documents: [KnowledgeDocument]) -> [KnowledgePassage] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var passages: [KnowledgePassage] = []
        for document in documents {
            let lines = document.text.components(separatedBy: .newlines)
            for start in stride(from: 0, to: lines.count, by: 8) {
                let quote = String(lines[start..<min(start + 16, lines.count)].joined(separator: "\n").prefix(3000))
                if words.allSatisfy({ (document.name + " " + quote).localizedCaseInsensitiveContains($0) }) {
                    passages.append(KnowledgePassage(documentID: document.id, title: document.name, url: document.url, line: start + 1, quote: quote, limited: document.limited))
                    if passages.count == 20 { return passages }
                }
            }
        }
        return passages
    }
}

private final class OfficeXMLText: NSObject, XMLParserDelegate {
    var text = "", insideText = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) { insideText = elementName == "w:t" || elementName == "t" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if insideText { text += string; if text.count > 220_000 { parser.abortParsing() } } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "w:t" || elementName == "t" { insideText = false }; if elementName == "w:p" || elementName == "p" { text += "\n" } }
}
private enum OfficeDocumentRead {
    static func text(_ data: Data) throws -> String {
        guard !String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<!DOCTYPE") else { throw PuddleError("Documents with XML document types are unsupported.") }
        let parser = XMLParser(data: data), delegate = OfficeXMLText(); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse() || delegate.text.count > 200_000 else { throw PuddleError("The DOCX text could not be read.") }
        return delegate.text
    }
    static func documentXML(_ data: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-document-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("captured.docx")
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PuddleError("The document snapshot could not be prepared.") }
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        var data = Data()
        while let bytes = try pipe.fileHandleForReading.read(upToCount: 65536), !bytes.isEmpty {
            if data.count + bytes.count > 4 * 1024 * 1024 { process.terminate(); pipe.fileHandleForReading.closeFile(); process.waitUntilExit(); timeout.cancel(); throw PuddleError("The DOCX XML exceeds its extraction limit.") }
            data.append(bytes)
        }
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { throw PuddleError("The DOCX archive could not be read.") }
        return data
    }
}
