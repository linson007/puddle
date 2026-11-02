import Foundation
import XCTest
import PuddleCore

enum LiveInferenceFixture {
    static func client() throws -> LocalInferenceClient {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PUDDLE_LIVE_INFERENCE_ADDRESS"] else {
            throw XCTSkip("Set PUDDLE_LIVE_INFERENCE_ADDRESS to a running local server for synthetic evaluations")
        }
        return try LocalInferenceClient(address: address, apiKey: environment["PUDDLE_LIVE_INFERENCE_KEY"] ?? "",
            modelID: environment["PUDDLE_LIVE_INFERENCE_MODEL"] ?? "")
    }
}
