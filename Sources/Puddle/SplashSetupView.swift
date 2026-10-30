import SwiftUI
import PuddleCore

struct SplashSetupView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var setup: SplashSetupController
    @Environment(\.dismiss) private var dismiss
    @State private var address = "http://127.0.0.1:8000"
    @State private var key = ""
    @State private var preset = SplashModelPreset.compact
    @State private var saved = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PuddleMark(size: 44)
                VStack(alignment: .leading) {
                    Text("Set up local AI").font(.title2.bold())
                    Text("Get a working model on this Mac, one step at a time.").foregroundStyle(.secondary)
                }
                Spacer(); Button("Close") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("1. Check this Mac") {
                        if let hardware = setup.hardware {
                            Text("\(hardware.chip) · \(hardware.memoryGB) GB memory · macOS \(hardware.os.majorVersion).\(hardware.os.minorVersion)")
                            if let disk = hardware.freeDiskBytes { Text("\(disk / 1_073_741_824) GB disk space available").font(.caption).foregroundStyle(.secondary) }
                            ForEach(hardware.issues(for: preset), id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                        }
                    }
                    section("2. Find or install Splash") {
                        HStack {
                            Text(setup.executable.isEmpty ? "Splash wasn’t found automatically." : setup.executable).font(.callout).textSelection(.enabled)
                            Spacer(); Button("Choose Splash…") { setup.chooseExecutable() }
                        }
                        if setup.executable.isEmpty {
                            if setup.brew != nil {
                                Text("Install from incoai’s Homebrew tap. This downloads Splash and dependencies; model weights download when you start a model.").font(.caption).foregroundStyle(.secondary)
                                Button("Install Splash") { setup.install() }.disabled(setup.isInstalling || setup.ownsServer || store.demo || store.state.settings.networkDisabled)
                            } else {
                                Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                                Text("Then refresh discovery, or choose an existing Splash installation.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("Refresh discovery") { setup.inspect() }.disabled(setup.isInstalling)
                            Link("Splash installation guide", destination: URL(string: "https://github.com/incoai/splash#quick-start")!)
                        }.font(.caption)
                    }
                    section("3. Choose and start a model") {
                        Picker("Model preset", selection: $preset) { ForEach(SplashModelPreset.allCases) { Text($0.title).tag($0) } }
                        Text(preset.detail).font(.callout).foregroundStyle(.secondary)
                        Text(preset.model).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Allow about \(preset.diskBudgetGB) GB of disk space. Downloads use your Hugging Face cache. Starting may contact the model host to check for updates.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(store.state.settings.networkDisabled ? "Start Cached Model Offline" : "Download & Start Model") {
                                address = "http://127.0.0.1:8000"; key = ""; saved = false
                                setup.start(preset: preset, port: 8000, offline: store.state.settings.networkDisabled)
                            }.disabled(setup.executable.isEmpty || setup.isInstalling || setup.ownsServer || setup.hardware?.issues(for: preset).isEmpty != true || store.demo)
                            if setup.ownsServer || setup.isInstalling { Button("Stop Puddle’s process") { setup.stop(); store.splashModel = nil } }
                        }
                        Text("Already running Splash? Continue below. Puddle only stops a process it starts; it won’t stop an existing server.").font(.caption).foregroundStyle(.secondary)
                    }
                    section("4. Verify your first reply and tools") {
                        TextField("Local server address", text: $address).textFieldStyle(.roundedBorder)
                        SecureField("API key, if required", text: $key).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(setup.isVerifying ? "Verifying…" : "Test Reply & Tool Calling") {
                                do { setup.verify(client: try store.setupClient(address: address, key: key)) }
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
                                        automatic: store.state.settings.automaticallyCheck, summarize: store.state.settings.automaticallySummarize, testConnection: true)
                                    saving = false; saved = store.errorMessage == nil && store.splashModel != nil
                                }
                            }.buttonStyle(.borderedProminent).disabled(saving)
                            if saved { Label("Connection saved. You’re ready to talk to Puddle.", systemImage: "checkmark.circle.fill").foregroundStyle(PuddleStyle.teal) }
                        }
                    }
                    if !setup.status.isEmpty { Text(setup.status).font(.callout).textSelection(.enabled) }
                    if let error = setup.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if let error = store.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if !setup.output.isEmpty { DisclosureGroup("Setup log") { Text(setup.output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                }.padding(.vertical, 6)
            }
            Divider()
            Text("AI stays on this Mac. Splash continues when this window closes. Quitting Puddle stops the process it started.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 730, height: 720).tint(PuddleStyle.teal)
            .onAppear { setup.inspect(); preset = setup.hardware?.recommendation ?? .compact; address = store.state.settings.splashAddress; key = store.apiKey }
            .onChange(of: address) { _, _ in saved = false; setup.invalidateVerification() }
            .onChange(of: key) { _, _ in saved = false; setup.invalidateVerification() }
            .onDisappear { setup.invalidateVerification() }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}
