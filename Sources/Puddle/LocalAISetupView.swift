import SwiftUI
import PuddleCore

struct LocalAISetupView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var setup: LocalAISetupController
    @Environment(\.dismiss) private var dismiss
    @State private var address = "http://127.0.0.1:8000"
    @State private var modelID = ""
    @State private var key = ""
    @State private var saved = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PuddleMark(size: 44)
                VStack(alignment: .leading) {
                    Text("Set up local AI").font(.title2.bold())
                    Text("Connect your preferred local model server.").foregroundStyle(.secondary)
                }
                Spacer(); Button("Close") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    connection
                    if !setup.status.isEmpty { Text(setup.status).font(.callout).textSelection(.enabled) }
                    if let error = setup.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if let error = store.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(.vertical, 6)
            }
            Divider()
            Text("Puddle connects only to servers on this Mac. Choose a locally running model in your server; the server controls where inference runs. Start and stop your model server in its own app or terminal.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 730, height: 720).tint(PuddleStyle.teal)
            .onAppear { address = store.state.settings.inferenceAddress; modelID = store.state.settings.inferenceModelID; key = store.apiKey }
            .onChange(of: address) { _, _ in saved = false; setup.invalidateVerification() }
            .onChange(of: modelID) { _, _ in saved = false; setup.invalidateVerification() }
            .onChange(of: key) { _, _ in saved = false; setup.invalidateVerification() }
            .onDisappear { setup.invalidateVerification() }
    }

    private var connection: some View {
        section("Connect and verify local AI") {
            Text("Use a server with an OpenAI-compatible API. Start it and load a local chat model, then enter its address below.").font(.callout).foregroundStyle(.secondary)
            Text("Common addresses: Ollama · localhost:11434, LM Studio · localhost:1234, llama.cpp · localhost:8080, Splash · localhost:8000. Include http://; /v1 is optional.").font(.caption).foregroundStyle(.secondary)
            Text("We suggest Splash, but you can use any compatible local provider.").font(.callout).foregroundStyle(.secondary)
            Link("Explore Splash", destination: URL(string: "https://github.com/incoai/splash")!).font(.caption)
            TextField("Local server address", text: $address).textFieldStyle(.roundedBorder)
            TextField("Model ID (optional)", text: $modelID).textFieldStyle(.roundedBorder)
            Text("Leave Model ID blank to use the first model in /v1/models. Tool use needs a model and server configured for function calling.").font(.caption).foregroundStyle(.secondary)
            SecureField("API key, if required", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Button(setup.isVerifying ? "Verifying…" : "Test Reply & Tool Calling") {
                    do { setup.verify(client: try store.setupClient(address: address, key: key, modelID: modelID)) }
                    catch { store.errorMessage = error.localizedDescription }
                }.disabled(setup.isVerifying || store.demo)
                if setup.isVerifying { ProgressView().controlSize(.small); Button("Cancel test") { setup.invalidateVerification() } }
            }
            Text("Two synthetic prompts go to your local model. This doesn’t access mail, files, or tasks.").font(.caption).foregroundStyle(.secondary)
            if let result = setup.verification {
                Label("Reply verified · \(result.model.id)", systemImage: "checkmark.circle.fill").foregroundStyle(PuddleStyle.teal)
                Text(result.answer).font(.callout).textSelection(.enabled)
                Label(result.toolCalling ? "Tool calling verified" : "Tool calling needs attention", systemImage: result.toolCalling ? "checkmark.circle.fill" : "exclamationmark.circle")
                if let diagnostic = result.toolDiagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let capacity = result.model.contextTokens { Text("Server context: \(capacity.formatted()) tokens").font(.caption).foregroundStyle(.secondary) }
                Button(saving ? "Saving…" : "Use This Connection") {
                    saving = true
                    Task {
                        await store.saveSettings(address: address, key: key, interval: store.state.settings.pollSeconds,
                            automatic: store.state.settings.automaticallyCheck, summarize: store.state.settings.automaticallySummarize, testConnection: true, modelID: modelID)
                        saving = false; saved = store.errorMessage == nil && store.inferenceModel != nil
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
                if saved { Label("Connection saved. You’re ready to talk to Puddle.", systemImage: "checkmark.circle.fill").foregroundStyle(PuddleStyle.teal) }
            }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}
