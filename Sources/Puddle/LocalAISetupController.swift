import Foundation
import Combine
import PuddleCore

@MainActor final class LocalAISetupController: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var isVerifying = false
    @Published private(set) var verification: LocalAISetupVerification?
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var revision = UUID()

    func verify(client: LocalInferenceClient) {
        guard !isVerifying else { return }
        let expected = UUID(); revision = expected
        isVerifying = true; verification = nil; error = nil; status = ""
        operation = Task {
            do {
                let result = try await client.verifySetup()
                guard !Task.isCancelled, revision == expected else { return }
                verification = result; isVerifying = false
                status = result.toolCalling ? "Local reply and tool calling verified." : "Local replies work. Tool calling did not pass; check your server and model configuration."
            } catch {
                guard revision == expected else { return }
                isVerifying = false
                if !(error is CancellationError) {
                    self.error = error.localizedDescription + " Check that your server is running, the model is loaded, and the address, model ID and API key are correct."
                }
            }
        }
    }

    func invalidateVerification() {
        revision = UUID(); operation?.cancel(); operation = nil
        verification = nil; isVerifying = false; status = ""; error = nil
    }
}
