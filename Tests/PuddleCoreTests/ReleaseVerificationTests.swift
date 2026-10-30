import CryptoKit
import Foundation
import XCTest
@testable import PuddleCore

final class ReleaseVerificationTests: XCTestCase {
    private func envelope(_ release: PuddleRelease, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let payload = try JSONEncoder().encode(release)
        return try JSONEncoder().encode(SignedReleaseManifest(payload: payload, signature: key.signature(for: payload)))
    }
    func testSignedManifestRejectsWrongKeyDowngradeAndUnsupportedOS() throws {
        let key = Curve25519.Signing.PrivateKey(), hash = String(repeating: "a", count: 64)
        let release = PuddleRelease(version: "1.2", build: 12, downloadURL: URL(string: "https://releases.example.com/Puddle.zip")!, sha256: hash, minimumOSMajor: 26, minimumOSMinor: 4)
        let data = try envelope(release, key: key), os = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        XCTAssertEqual(try ReleaseVerification.release(data, publicKey: key.publicKey.rawRepresentation, currentBuild: 11, os: os)?.build, 12)
        XCTAssertNil(try ReleaseVerification.release(data, publicKey: key.publicKey.rawRepresentation, currentBuild: 12, os: os))
        XCTAssertThrowsError(try ReleaseVerification.release(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, currentBuild: 1, os: os))
        XCTAssertThrowsError(try ReleaseVerification.release(data, publicKey: key.publicKey.rawRepresentation, currentBuild: 1, os: OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 0)))
    }
    func testPayloadTamperingUnsafeURLAndDownloadMismatchAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey(), bytes = Data("fixture archive".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let release = PuddleRelease(version: "1.0", build: 2, downloadURL: URL(string: "https://releases.example.com/Puddle.zip")!, sha256: hash)
        XCTAssertNoThrow(try ReleaseVerification.verifyDownload(bytes, release: release))
        XCTAssertThrowsError(try ReleaseVerification.verifyDownload(Data("changed".utf8), release: release))
        let signed = try JSONDecoder().decode(SignedReleaseManifest.self, from: envelope(release, key: key))
        let altered = try JSONEncoder().encode(SignedReleaseManifest(payload: signed.payload + Data([32]), signature: signed.signature))
        XCTAssertThrowsError(try ReleaseVerification.release(altered, publicKey: key.publicKey.rawRepresentation, currentBuild: 1))
        let unsafe = PuddleRelease(version: "1.0", build: 2, downloadURL: URL(string: "http://releases.example.com/Puddle.zip")!, sha256: hash)
        XCTAssertThrowsError(try ReleaseVerification.release(envelope(unsafe, key: key), publicKey: key.publicKey.rawRepresentation, currentBuild: 1))
    }
}
