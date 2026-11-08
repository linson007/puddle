import Foundation
import XCTest
import PuddleCore

final class DiagnosticsTests: XCTestCase {
    func testSupportEventsExcludeDescriptionsPathsDomainsAndCallerText() throws {
        let privateValue = "secret-token /Users/private/account@example.test"
        PuddleDiagnostics.failure(.oauth, privateValue, NSError(domain: privateValue, code: 17, userInfo: [NSLocalizedDescriptionKey: privateValue]))
        let data = try JSONEncoder().encode(PuddleDiagnostics.supportEvents())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(privateValue))
        let last = try XCTUnwrap(PuddleDiagnostics.supportEvents().last)
        XCTAssertEqual(last.domain, "application"); XCTAssertEqual(last.code, 17)
    }
    func testSwiftAndURLSessionCancellationsDoNotLogFailures() {
        for error: Error in [CancellationError(), URLError(.cancelled), NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)] {
            XCTAssertTrue(PuddleDiagnostics.isCancellation(error))
            XCTAssertFalse(PuddleDiagnostics.failure(.network, "Synthetic cancellation", error))
        }
    }
    func testRealFailuresAndPolicyChangesStillLog() {
        for error: Error in [URLError(.timedOut), NSError(domain: "OtherDomain", code: NSURLErrorCancelled),
                             PuddleError("External request interrupted by policy change")] {
            XCTAssertFalse(PuddleDiagnostics.isCancellation(error))
            XCTAssertTrue(PuddleDiagnostics.failure(.network, "Synthetic failure", error))
        }
    }
}
