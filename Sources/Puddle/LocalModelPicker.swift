import SwiftUI
import PuddleCore

@MainActor final class LocalModelDiscovery: ObservableObject {
    @Published private(set) var models: [LocalInferenceModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var didLoad = false
    private(set) var operation: Task<Void, Never>?
    private var revision = UUID()

    func load(client: LocalInferenceClient) {
        reset()
        let expected = revision
        isLoading = true
        operation = Task {
            do {
                let found = try await client.availableModels()
                guard !Task.isCancelled, revision == expected else { return }
                models = found; didLoad = true; isLoading = false
            } catch {
                guard revision == expected else { return }
                isLoading = false
                if !PuddleDiagnostics.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }

    func reset() {
        revision = UUID(); operation?.cancel(); operation = nil
        models = []; isLoading = false; error = nil; didLoad = false
    }
}

/// Shared by guided setup and Settings; discovery never changes the user's selection.
struct LocalModelPicker: View {
    @ObservedObject var store: PuddleStore
    let address: String
    let key: String
    @Binding var modelID: String
    @StateObject private var discovery = LocalModelDiscovery()
    @State private var configurationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.text("Model ID (optional)"), text: $modelID).textFieldStyle(.roundedBorder)
                Button(L10n.text("Find models")) {
                    configurationError = nil
                    do { discovery.load(client: try store.setupClient(address: address, key: key, modelID: "")) }
                    catch { configurationError = error.localizedDescription }
                }.disabled(discovery.isLoading || store.demo)
            }
            if discovery.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Looking for models…")).font(.caption)
                    Button(L10n.text("Cancel")) { discovery.reset() }
                }
            }
            if discovery.didLoad {
                if discovery.models.isEmpty {
                    Text(L10n.text("No models listed. Load a chat model in your server, then find models again."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.text("Available models"), selection: $modelID) {
                        Text(L10n.text("Automatic (first listed model)")).tag("")
                        if !modelID.isEmpty, !discovery.models.contains(where: { $0.id == modelID }) {
                            Text(verbatim: modelID).tag(modelID)
                        }
                        ForEach(discovery.models) { model in Text(verbatim: model.id).tag(model.id) }
                    }
                    Text(L10n.text("Listed by your server. Test a reply and tool calling to check compatibility."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = configurationError ?? discovery.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .onChange(of: address) { _, _ in reset() }
        .onChange(of: key) { _, _ in reset() }
        .onDisappear { reset() }
    }

    private func reset() { discovery.reset(); configurationError = nil }
}
