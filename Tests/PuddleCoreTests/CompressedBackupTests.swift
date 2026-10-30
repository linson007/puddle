import CryptoKit
import Foundation
import XCTest
@testable import PuddleCore

final class CompressedBackupTests: XCTestCase {
    func testLegacyVersionOneIsStillReadableAndNewFormatPreservesAllContent() throws {
        var state = AppSnapshot(); state.chat = [ChatLine(role: "user", content: String(repeating: "Synthetic long-term saved conversation. ", count: 10000))]
        let data = try WorkspaceBackup.encode(state)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 2)
        let compressed = Data(base64Encoded: object["payload"] as! String)!
        let plain = try (compressed as NSData).decompressed(using: .lzfse) as Data
        XCTAssertLessThan(data.count, plain.count / 2)
        XCTAssertEqual(WorkspaceBackup.merging(try WorkspaceBackup.inspect(data), into: AppSnapshot()).0.conversations[0].lines, state.chat)
        object["version"] = 1; object["payload"] = plain.base64EncodedString()
        object["sha256"] = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
        object.removeValue(forKey: "compression"); object.removeValue(forKey: "uncompressedBytes")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(WorkspaceBackup.merging(try WorkspaceBackup.inspect(legacy), into: AppSnapshot()).0.conversations[0].lines, state.chat)
    }
    func testInvalidDecodedSizesAndCodecsAreRejectedBeforeAllocatingUnboundedMemory() throws {
        let data = try WorkspaceBackup.encode(AppSnapshot())
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for size in [-1, 0, 1, 121 * 1024 * 1024, Int.max] {
            var object = original; object["uncompressedBytes"] = size
            XCTAssertThrowsError(try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: object)))
        }
        var object = original; object["compression"] = "unknown"
        XCTAssertThrowsError(try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: object)))
    }
}
