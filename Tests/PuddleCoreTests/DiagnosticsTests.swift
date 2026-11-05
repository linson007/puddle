import Foundation
import XCTest
import PuddleCore

final class DiagnosticsTests: XCTestCase {
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
