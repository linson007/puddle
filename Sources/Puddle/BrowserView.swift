import SwiftUI
import PuddleCore

struct BrowserView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: BrowserWorkspace
    @State private var driverPath = BrowserWorkspace.defaultDriverPath
    @State private var address = "https://example.com"
    @State private var task = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Browser").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("Let Puddle read pages and use a browser alongside you, powered by Cua.")
                    .foregroundStyle(.secondary)
                if store.demo {
                    Label("Browser control is available in the live app. Demo never opens or controls a real browser.", systemImage: "flask")
                } else if store.state.settings.networkDisabled || store.privateSession {
                    Label("Browser sessions are paused by your privacy settings.", systemImage: "pause.circle")
                } else if workspace.isConnected {
                    HStack {
                        Label("Cua browser connected", systemImage: "checkmark.circle.fill").foregroundStyle(PuddleStyle.teal)
                        Spacer()
                        Button("Show Browser") { workspace.showBrowser() }
                        Button("Stop Browser", role: .destructive) { store.stopAI(); workspace.stop() }
                    }
                    HStack {
                        TextField("Website address", text: $address).textFieldStyle(.roundedBorder).onSubmit(navigate)
                        Button("Open Page", action: navigate).disabled(workspace.isBusy || store.isThinking)
                        Button("Read Page") { Task { _ = try? await workspace.observe() } }.disabled(workspace.isBusy || store.isThinking)
                    }
                    HStack {
                        TextField("Ask Puddle to do something in this browser", text: $task).textFieldStyle(.roundedBorder).onSubmit(ask)
                        Button("Start Errand", action: ask).buttonStyle(.borderedProminent)
                            .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isThinking || workspace.isBusy)
                    }
                    Text("Try: “Open Wikipedia, search for Ada Lovelace, and summarize the page.” Puddle reads page text and controls; it does not interpret screenshots.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect Cua Driver").font(.headline)
                        Text("Install Cua Driver, then grant it Accessibility and Screen Recording in macOS System Settings. Start its app before connecting here.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Cua installation and permissions", destination: URL(string: "https://cua.ai/docs/cua-driver/quickstart")!)
                        HStack {
                            TextField("cua-driver executable", text: $driverPath).textFieldStyle(.roundedBorder)
                            Button("Choose…", action: chooseDriver).disabled(workspace.isBusy)
                        }
                        Button(workspace.isBusy ? "Starting browser…" : "Start Cua Browser") {
                            UserDefaults.standard.set(driverPath, forKey: "cuaDriverPath")
                            Task { await workspace.connect(path: driverPath) }
                        }.buttonStyle(.borderedProminent).disabled(workspace.isBusy || store.isThinking)
                        if workspace.isBusy { Button("Cancel") { workspace.stop() } }
                    }.padding(18).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                if workspace.isBusy { ProgressView("Working with Cua…").controlSize(.small) }
                if let error = workspace.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                Text("Uses a separate Chrome or Edge profile. Navigation, clicks and typing requested by the assistant wait for your review in chat. Page text goes to your local Splash model. Stop Browser ends this session and its dedicated browser; connection permission is not restored after restarting Puddle.")
                    .font(.caption).foregroundStyle(.secondary)
                if let page = workspace.page {
                    Divider()
                    Text("Last observed page").font(.headline)
                    Text(page.summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                BrowserErrandsView(store: store, workspace: workspace)
            }.frame(maxWidth: 900, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear {
            if !store.demo, let saved = UserDefaults.standard.string(forKey: "cuaDriverPath") { driverPath = saved }
        }
    }
    private func navigate() {
        guard !store.isThinking, !workspace.isBusy else { return }
        Task { _ = try? await workspace.act(.navigate(address.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }
    private func ask() {
        guard !store.isThinking, !workspace.isBusy, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = task; task = ""; Task { await store.startBrowserErrand(question) }
    }
    private func chooseDriver() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Choose the installed cua-driver executable."
        if panel.runModal() == .OK, let url = panel.url { driverPath = url.path }
    }
}

struct BrowserControlBanner: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: BrowserWorkspace
    var body: some View {
        if workspace.isConnected || workspace.isBusy {
            HStack {
                Label(workspace.isConnected ? "Cua browser connected" : "Starting Cua browser…", systemImage: "globe")
                Spacer()
                Button("Browser") { store.section = .browser }
                Button("Stop Browser") { store.stopAI(); workspace.stop() }
            }.font(.caption).padding(.horizontal, 24).padding(.vertical, 9).background(PuddleStyle.teal.opacity(0.08))
        }
    }
}
