import CoreServices
import Darwin
import Foundation
import XCTest
@testable import PuddleCore

final class RemoteAttachmentFileTests: XCTestCase {
    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-quarantine-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory.appendingPathComponent("download.zip")
    }
    func testAllRemoteAttachmentsRetainQuarantineOriginAndPrivatePermissions() throws {
        let file = try destination(), origin = URL(string: "https://mail.google.com/mail/u/0/#all/fixture")!
        try RemoteAttachmentFile.write(Data("Synthetic attachment".utf8), to: file, origin: origin)
        XCTAssertEqual(try Data(contentsOf: file), Data("Synthetic attachment".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let quarantine = try XCTUnwrap(URL(fileURLWithPath: file.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(quarantine[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeEmailAttachment as String)
        let size = getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        XCTAssertGreaterThan(size, 0)
        var provenance = Data(count: max(0, size))
        let read = provenance.withUnsafeMutableBytes { getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(read, size)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: provenance, format: nil) as? [String], [origin.absoluteString])
        XCTAssertGreaterThan(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
        try RemoteAttachmentFile.write(Data("Replacement".utf8), to: file, origin: origin)
        XCTAssertEqual(try Data(contentsOf: file), Data("Replacement".utf8))
        XCTAssertGreaterThan(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }
    func testQuarantineFailurePublishesNothingAndPreservesExistingDestination() throws {
        let file = try destination()
        for existing in [false, true] {
            if existing { try Data("Original".utf8).write(to: file) }
            XCTAssertThrowsError(try RemoteAttachmentFile.write(Data("Untrusted".utf8), to: file, quarantine: { _ in throw PuddleError("Fixture metadata failure") }))
            if existing { XCTAssertEqual(try Data(contentsOf: file), Data("Original".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.hasPrefix(".puddle-") }, [])
        }
    }
}
