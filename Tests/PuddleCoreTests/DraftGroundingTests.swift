import XCTest
@testable import PuddleCore

final class DraftGroundingTests: XCTestCase {
    func testSourceRequestDoesNotAuthorizeInventedCompletion() {
        XCTAssertThrowsError(try DraftGrounding.validate("I’ve reviewed the document and have feedback.", userContext: "Draft a concise reply asking for the agenda."))
        XCTAssertThrowsError(try DraftGrounding.validate("We have already approved the plan.", userContext: "Ask when the plan is ready."))
        XCTAssertThrowsError(try DraftGrounding.validate("I reviewed the plan.", userContext: "I have not reviewed the plan. Do not say I reviewed it."))
        XCTAssertNoThrow(try DraftGrounding.validate("Could you share the review agenda?", userContext: "Draft a concise reply."))
    }
    func testUserProvidedCompletedWorkCanBeRetained() {
        XCTAssertNoThrow(try DraftGrounding.validate("I have reviewed the document.", userContext: "I reviewed the document. Ask about next steps."))
    }
}
