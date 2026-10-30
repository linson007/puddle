import Darwin
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import PuddleCore

final class KnowledgeBoundaryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("puddle-knowledge-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testHeldSourceRejectsReplacedFileAndAncestorInsteadOfReadingOutsideRoot() throws {
        let base = try folder(), root = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside")
        let fm = FileManager.default
        for url in [root, outside, root.appendingPathComponent("nested")] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("Private outside data".utf8).write(to: outside.appendingPathComponent("note.txt"))
        try Data("Selected source".utf8).write(to: root.appendingPathComponent("nested/note.txt"))
        let files = try KnowledgeFiles(root: root)
        XCTAssertEqual(try files.inventory().paths, ["nested/note.txt"])
        try fm.moveItem(at: root.appendingPathComponent("nested"), to: root.appendingPathComponent("original"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("nested"), withDestinationURL: outside)
        XCTAssertThrowsError(try files.capture("nested/note.txt", maximumBytes: 100))
        let file = root.appendingPathComponent("original/note.txt")
        try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("note.txt"))
        XCTAssertThrowsError(try files.capture("original/note.txt", maximumBytes: 100))
        for path in ["../outside/note.txt", "/outside/note.txt", "original//note.txt", "./original/note.txt"] { XCTAssertThrowsError(try files.capture(path, maximumBytes: 100)) }
    }
    func testCanonicalParentWalkRejectsAncestorReplacementBeforeRootIsOpened() throws {
        let base = try folder(), original = base.appendingPathComponent("ancestor/parent"), outside = base.appendingPathComponent("outside/parent")
        for url in [original, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let pointer = try XCTUnwrap(realpath(original.path, nil)); let canonical = String(cString: pointer); free(pointer)
        try FileManager.default.moveItem(at: base.appendingPathComponent("ancestor"), to: base.appendingPathComponent("old-ancestor"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("ancestor"), withDestinationURL: base.appendingPathComponent("outside"))
        XCTAssertThrowsError(try KnowledgeFiles.directoryDescriptor(canonical))
    }
    func testInventoryPreservesHiddenFlagAndPackageExclusions() throws {
        let base = try folder(), hiddenFile = base.appendingPathComponent("hidden.txt"), hiddenFolder = base.appendingPathComponent("hidden-folder"), package = base.appendingPathComponent("Example.app")
        for url in [hiddenFolder, package] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        for url in [hiddenFile, hiddenFolder.appendingPathComponent("private.txt"), package.appendingPathComponent("private.txt"), base.appendingPathComponent("visible.txt")] { try Data("Fixture text".utf8).write(to: url) }
        XCTAssertEqual(chflags(hiddenFile.path, UInt32(UF_HIDDEN)), 0); XCTAssertEqual(chflags(hiddenFolder.path, UInt32(UF_HIDDEN)), 0)
        XCTAssertEqual(try KnowledgeFiles(root: base).inventory().paths, ["visible.txt"])
    }
    func testSelectedLinksAndNonregularFilesAreRejectedButSystemParentAliasesWork() throws {
        let base = try folder(), file = base.appendingPathComponent("note.txt")
        try Data("Ordinary source".utf8).write(to: file)
        XCTAssertEqual(try LocalKnowledge.extract(file).0, "Ordinary source")
        let linked = base.appendingPathComponent("linked.txt"), folderLink = base.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: base)
        XCTAssertThrowsError(try KnowledgeFiles(root: linked)); XCTAssertThrowsError(try KnowledgeFiles(root: folderLink))
        let fifo = base.appendingPathComponent("pipe.txt"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try KnowledgeFiles(root: fifo))
        let files = try KnowledgeFiles(root: base)
        XCTAssertThrowsError(try files.capture("pipe.txt", maximumBytes: 100))
        XCTAssertThrowsError(try files.capture("note.txt", maximumBytes: 2))
    }
    func testCapturedBytesSurviveSourceReplacementAndPreserveTextAndPDFDecoding() throws {
        let base = try folder(), file = base.appendingPathComponent("note.txt")
        try XCTUnwrap("Captured Unicode café".data(using: .utf16)).write(to: file)
        let files = try KnowledgeFiles(root: base), captured = try files.capture("note.txt", maximumBytes: 1000)
        try FileManager.default.removeItem(at: file)
        try Data("Replacement content".utf8).write(to: file)
        XCTAssertEqual(try LocalKnowledge.extract(captured.data, kind: "txt").0, "Captured Unicode café")
        let pdf = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        var box = CGRect(x: 0, y: 0, width: 400, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 40)
        let attributed = NSAttributedString(string: "Captured PDF source", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage(); context.closePDF()
        XCTAssertTrue(try LocalKnowledge.extract(pdf as Data, kind: "pdf").0.contains("Captured PDF source"))
    }
    func testCapturedDOCXUsesPrivateSnapshotAndRejectsDocumentTypes() throws {
        let base = try folder(), word = base.appendingPathComponent("word"), archive = base.appendingPathComponent("source.docx")
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let xml = #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Captured document text</w:t></w:r></w:p></w:body></w:document>"#
        try Data(xml.utf8).write(to: word.appendingPathComponent("document.xml"))
        func zip() throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = base
            process.arguments = ["-q", archive.path, "word/document.xml"]; try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try zip()
        let files = try KnowledgeFiles(root: base), captured = try files.capture("source.docx", maximumBytes: 1_000_000)
        try FileManager.default.removeItem(at: archive)
        XCTAssertTrue(try LocalKnowledge.extract(captured.data, kind: "docx").0.contains("Captured document text"))
        try Data(xml.replacingOccurrences(of: "<w:document", with: "<!DOCTYPE x [<!ENTITY external SYSTEM 'file:///never-read'>]><w:document").utf8).write(to: word.appendingPathComponent("document.xml"))
        try zip()
        XCTAssertThrowsError(try LocalKnowledge.extract(Data(contentsOf: archive), kind: "docx"))
    }
}
