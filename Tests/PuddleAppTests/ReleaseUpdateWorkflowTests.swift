import CryptoKit
import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private actor UpdateHTTP: HTTPTransport {
    var responses: [String: (Data, Int)] = [:]
    var paths: [String] = []
    var held = false
    var continuations: [CheckedContinuation<Void, Never>] = []
    func set(_ path: String, _ data: Data, status: Int = 200) { responses[path] = (data, status) }
    func hold() { held = true }
    func resume() { held = false; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
    func count() -> Int { paths.count }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!, result = responses[url.path] ?? (Data(), 404)
        paths.append(url.path)
        // Deliberately ignores task cancellation to exercise stale-response guards.
        if held { await withCheckedContinuation { continuations.append($0) } }
        return (result.0, HTTPURLResponse(url: url, statusCode: result.1, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class ReleaseUpdateWorkflowTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-update-\(UUID())")
        let key = Curve25519.Signing.PrivateKey()
        let bytes = Data("Synthetic archive; never installed".utf8)
        let http = UpdateHTTP()
        var allowed = true
        var downloads: URL { root.appendingPathComponent("downloads") }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func configuration(_ overrides: [String: Any] = [:]) throws -> ReleaseUpdateConfiguration {
            let app = root.appendingPathComponent("Configured-\(UUID()).app"), contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "app.puddle.update-test.\(UUID().uuidString)", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "10", "PuddleUpdateManifestURL": "https://updates.puddle.test/feed.json",
                "PuddleUpdatePublicKey": key.publicKey.rawRepresentation.base64EncodedString()].merging(overrides) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return try ReleaseUpdateConfiguration(bundle: XCTUnwrap(Bundle(url: app)))
        }
        func manifest(build: Int = 11, signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let release = PuddleRelease(version: "1.1.0", build: build, downloadURL: URL(string: "https://updates.puddle.test/Puddle.zip")!, sha256: digest)
            let payload = try JSONEncoder().encode(release)
            return try JSONEncoder().encode(SignedReleaseManifest(payload: payload, signature: (signer ?? key).signature(for: payload)))
        }
        func controller() throws -> ReleaseUpdateController {
            let config = try configuration()
            return ReleaseUpdateController(transport: http, configuration: { config }, canConnect: { self.allowed }, downloadRoot: downloads)
        }
        func ready(_ controller: ReleaseUpdateController) async throws {
            await http.set("/feed.json", try manifest()); await http.set("/Puddle.zip", bytes)
            controller.check(); try await finished(controller)
            XCTAssertEqual(controller.release?.build, 11)
        }
        func finished(_ controller: ReleaseUpdateController) async throws {
            for _ in 0..<500 {
                if !controller.busy { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Update operation did not finish"); controller.cancel()
        }
        func waitForRequests(_ count: Int) async throws {
            for _ in 0..<500 {
                if await http.count() >= count { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Update request was not started")
        }
    }

    func testBundlePinnedFeedDownloadAndInstallerRecheck() async throws {
        let f = try Fixture(), updates = try f.controller()
        try await f.ready(updates); updates.download(); try await f.finished(updates)
        let file = try XCTUnwrap(updates.downloaded)
        XCTAssertEqual(try Data(contentsOf: file), f.bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        var opened: [URL] = []
        updates.openInstaller { opened.append($0); return true }; try await f.finished(updates)
        XCTAssertEqual(opened, [file])
        try Data("Changed after download".utf8).write(to: file)
        updates.openInstaller { opened.append($0); return true }; try await f.finished(updates)
        XCTAssertEqual(opened, [file]); XCTAssertNil(updates.downloaded)
        XCTAssertTrue(updates.status.contains("SHA-256"), updates.status)
    }

    func testFailedRecheckClearsEarlierReleaseAndInstaller() async throws {
        let f = try Fixture(), updates = try f.controller()
        try await f.ready(updates); updates.download(); try await f.finished(updates)
        XCTAssertNotNil(updates.downloaded)
        await f.http.set("/feed.json", try f.manifest(signer: Curve25519.Signing.PrivateKey()))
        updates.check(); try await f.finished(updates)
        XCTAssertNil(updates.release); XCTAssertNil(updates.downloaded)
        XCTAssertTrue(updates.status.contains("signature"), updates.status)
        let before = await f.http.count()
        updates.download(); let after = await f.http.count(); XCTAssertEqual(after, before)
    }

    func testCorruptAndInterruptedDownloadsLeaveNoInstallerAndRetryWorks() async throws {
        let f = try Fixture(), updates = try f.controller()
        try await f.ready(updates)
        await f.http.set("/Puddle.zip", Data("Truncated".utf8))
        updates.download(); try await f.finished(updates)
        XCTAssertNil(updates.downloaded); XCTAssertFalse(FileManager.default.fileExists(atPath: f.downloads.path))
        await f.http.set("/Puddle.zip", f.bytes); await f.http.hold()
        updates.download(); try await f.waitForRequests(3)
        updates.cancel(); await f.http.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(updates.downloaded); XCTAssertFalse(FileManager.default.fileExists(atPath: f.downloads.path))
        updates.check(); try await f.finished(updates)
        updates.download(); try await f.finished(updates)
        XCTAssertNotNil(updates.downloaded)
    }

    func testPauseAndCancelledLateFeedCannotPublishOrStartDownload() async throws {
        let f = try Fixture(), updates = try f.controller()
        await f.http.set("/feed.json", try f.manifest()); await f.http.hold()
        updates.check(); try await f.waitForRequests(1)
        f.allowed = false; updates.cancel()
        await f.http.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(updates.release); XCTAssertFalse(updates.busy)
        updates.check(); updates.download()
        let requests = await f.http.count(); XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.downloads.path))
        f.allowed = true; updates.check(); try await f.finished(updates)
        XCTAssertEqual(updates.release?.build, 11)
    }

    func testInvalidShippedConfigurationAndOldBuildDoNotOfferDownload() async throws {
        let f = try Fixture()
        for fields: [String: Any] in [["PuddleUpdateManifestURL": "http://updates.puddle.test/feed.json"],
            ["PuddleUpdatePublicKey": Data([1, 2, 3]).base64EncodedString()], ["CFBundleVersion": "0"]] {
            XCTAssertThrowsError(try f.configuration(fields))
        }
        let updates = try f.controller()
        await f.http.set("/feed.json", try f.manifest(build: 9))
        updates.check(); try await f.finished(updates)
        XCTAssertNil(updates.release); XCTAssertTrue(updates.status.contains("up to date"))
        updates.download(); let requests = await f.http.count(); XCTAssertEqual(requests, 1)
    }
}
