import XCTest

final class AsyncTestGateTests: XCTestCase {
    @MainActor func testMultiplePausesSignalOnceAndReleaseEveryWaiter() async throws {
        let gate = AsyncTestGate()
        gate.entered.assertForOverFulfill = true
        let first = Task { await gate.pause() }, second = Task { await gate.pause() }
        await fulfillment(of: [gate.entered], timeout: 5)
        try await waitForTestEvent("Both gate waiters entered") { await gate.waiterCount == 2 }
        await gate.release(); await gate.release()
        await first.value; await second.value
        await gate.pause()
        let remaining = await gate.waiterCount
        XCTAssertEqual(remaining, 0)
    }
}
