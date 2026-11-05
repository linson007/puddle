import Foundation
import XCTest

/// A fixture explicitly reports entry and remains blocked until the test releases
/// it. Cancellation is intentionally ignored to exercise late-result defenses.
actor AsyncTestGate {
    nonisolated let entered = XCTestExpectation(description: "Fixture reached controlled suspension")
    private var released = false
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiterCount: Int { waiters.count }
    func pause() async {
        if !signaled { signaled = true; entered.fulfill() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}
func waitForTestEvent(_ description: String, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out: \(description)")
            throw NSError(domain: "TestSynchronization", code: 1)
        }
        await Task.yield()
    }
}
