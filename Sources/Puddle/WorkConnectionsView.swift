import SwiftUI
import PuddleCore

struct WorkConnectionsView: View {
    @ObservedObject var store: PuddleStore
    @State private var showingGitHub = false
    @State private var showingAtlassian = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Developer work sources", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            Text("Read GitHub work, Jira requirements and Confluence documentation with your local assistant. Sign-in credentials stay in Keychain; searches go directly to the connected services.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("GitHub", systemImage: WorkService.github.icon).fontWeight(.semibold)
                    Spacer()
                    Text(store.githubConnection.map { "@\($0.login)" } ?? "Not connected").font(.caption).foregroundStyle(.secondary)
                }
                if let info = store.githubConnection {
                    Text(info.repositories.joined(separator: ", ")).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Last verified \(info.verifiedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(store.githubConnection == nil ? "Connect GitHub…" : "Manage GitHub…") { showingGitHub = true }.disabled(store.demo || store.isConnectingGitHub)
                    if store.githubConnection != nil {
                        Button("Test") { Task { await store.testWorkConnection(.github) } }.disabled(store.testingWorkConnections.contains(.github))
                        Button("Disconnect") { Task { await store.disconnectWorkConnection(.github) } }
                    }
                }
                if let error = store.workConnectionErrors[.github] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Jira & Confluence", systemImage: "books.vertical").fontWeight(.semibold)
                    Spacer()
                    Text(store.atlassianConnection == nil ? "Not connected" : "Atlassian authorized").font(.caption).foregroundStyle(.secondary)
                }
                if let info = store.atlassianConnection {
                    Text(info.services.map(\.title).sorted().joined(separator: " · ") + " · read/search").font(.caption).foregroundStyle(.secondary)
                    Picker("Atlassian site", selection: Binding(get: { info.selectedSiteID }, set: { id in Task { await store.chooseAtlassianSite(id) } })) {
                        Text("Choose a site").tag(Optional<String>.none)
                        ForEach(info.sites) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("Last verified \(info.verifiedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(store.atlassianConnection == nil ? "Connect Jira / Confluence…" : "Manage Atlassian Access…") { showingAtlassian = true }.disabled(store.demo || store.isConnectingAtlassian)
                    if store.atlassianConnection != nil {
                        Button("Test") { Task { await store.testWorkConnection(.jira) } }.disabled(store.testingWorkConnections.contains(.jira))
                        Button("Disconnect Atlassian") { Task { await store.disconnectWorkConnection(.jira) } }
                    }
                    if store.isConnectingAtlassian {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { store.cancelAtlassianSignIn() }
                    }
                }
                if !store.workAuthorizationStatus.isEmpty { Text(store.workAuthorizationStatus).font(.caption).foregroundStyle(.secondary) }
                ForEach([WorkService.jira, .confluence]) { service in
                    if let error = store.workConnectionErrors[service], service == .jira || error != store.workConnectionErrors[.jira] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
            Text("Read-only connectors. Puddle cannot change issues/pages, comment, merge PRs or trigger CI. Retrieved excerpts may remain in your chat history; disconnecting removes local credentials and current connector results.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .sheet(isPresented: $showingGitHub) { GitHubConnectionSheet(store: store) }
            .sheet(isPresented: $showingAtlassian) { AtlassianConnectionSheet(store: store) }
    }
}

private struct GitHubConnectionSheet: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var repositories = ""
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect GitHub").font(.title2).fontWeight(.semibold)
            Text("Use a fine-grained personal access token for the repositories you choose. Give it read access to Issues and Pull requests; Checks read access is optional for CI results. Paste it here, never into chat.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Create a fine-grained GitHub token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            SecureField("GitHub token", text: $token).textFieldStyle(.roundedBorder).disabled(store.isConnectingGitHub)
            Text("Repositories").font(.callout).fontWeight(.medium)
            TextField("owner/repository or https://github.com/owner/repository", text: $repositories, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(store.isConnectingGitHub)
                .accessibilityLabel("Repositories")
            Text("Paste repository URLs or owner/repository names, one per line or separated by commas. Up to 10 different repositories.")
                .font(.caption).foregroundStyle(.secondary)
            if let names = try? GitHubConnector.parseRepositories(repositories) {
                Text("Will connect \(names.count) \(names.count == 1 ? "repository" : "repositories"): " + names.joined(separator: ", "))
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).help(names.joined(separator: ", "))
            }
            Text("Only these repositories are searched and readable through this connector. Your token is stored in this Mac's Keychain and excluded from backups.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.workConnectionErrors[.github] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if store.isConnectingGitHub { ProgressView().controlSize(.small); Text("Verifying account and repository access…").font(.caption) }
                Spacer(); Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Test GitHub") {
                    let submittedToken = token, submittedRepositories = repositories
                    task = Task { if await store.connectGitHub(token: submittedToken, repositoryText: submittedRepositories) { token = ""; dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(store.isConnectingGitHub || token.isEmpty || repositories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 590).onAppear { repositories = store.githubConnection?.repositories.joined(separator: "\n") ?? "" }
            .onChange(of: token) { _, _ in store.workConnectionErrors[.github] = nil }
            .onChange(of: repositories) { _, _ in store.workConnectionErrors[.github] = nil }
            .onDisappear { task?.cancel(); token = "" }
    }
}

private struct AtlassianConnectionSheet: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var jira = true
    @State private var confluence = true
    @State private var started = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Jira & Confluence").font(.title2).fontWeight(.semibold)
            Text("Sign in through Atlassian's browser consent screen. Choose the site you want Puddle to read; no app registration or API token is required.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Read and search Jira work", isOn: $jira)
            Toggle("Read and search Confluence documentation", isOn: $confluence)
            Text("Uses Atlassian's official remote MCP service with read/search permissions. Your organization may require an administrator to approve this connection. Local inference continues on your Mac; connector requests go to Atlassian.")
                .font(.caption).foregroundStyle(.secondary)
            if store.isConnectingAtlassian { HStack { ProgressView().controlSize(.small); Text(store.workAuthorizationStatus).font(.callout) } }
            if let error = store.workConnectionErrors[.jira] ?? store.workConnectionErrors[.confluence] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(store.isConnectingAtlassian ? "Cancel Sign-in" : "Close") { if store.isConnectingAtlassian { store.cancelAtlassianSignIn() }; dismiss() }
                Button("Sign in with Atlassian") {
                    started = true; store.beginAtlassianSignIn(services: Set((jira ? [WorkService.jira] : []) + (confluence ? [.confluence] : [])))
                }.buttonStyle(.borderedProminent).disabled(store.isConnectingAtlassian || (!jira && !confluence))
            }
        }.padding(28).frame(width: 590)
            .onAppear { if let info = store.atlassianConnection { jira = info.services.contains(.jira); confluence = info.services.contains(.confluence) } }
            .onChange(of: store.atlassianConnection?.verifiedAt) { _, _ in if started && store.atlassianConnection != nil { dismiss() } }
            .onDisappear { if store.isConnectingAtlassian { store.cancelAtlassianSignIn() } }
    }
}

struct WorkSourcesView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: WorkSourcesWorkspace
    @State private var query = ""
    @State private var provider = "all"
    @State private var selected: WorkItem?
    private var services: [WorkService] { provider == "all" ? store.connectedWorkServices : store.connectedWorkServices.filter { $0.rawValue == provider } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Issues, pull requests & documentation", systemImage: "tray.full").font(.headline)
                Spacer()
                Button("Manage Connections") { store.section = .connections }.buttonStyle(.link)
            }
            if store.connectedWorkServices.isEmpty {
                Text("Connect GitHub, Jira or Confluence to bring real work and project context into Puddle.").foregroundStyle(.secondary)
                Button("Connect Work Sources") { store.section = .connections }
            } else {
                HStack {
                    TextField("Search connected work", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                    Picker("Source", selection: $provider) {
                        Text("All sources").tag("all")
                        ForEach(store.connectedWorkServices) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().accessibilityLabel("Source").frame(width: 150)
                    Button("Search") { search() }.disabled(workspace.isSearching || services.isEmpty)
                }
                HStack {
                    Button("Open work & recent docs") { query = ""; search() }.disabled(workspace.isSearching || services.isEmpty)
                    Button("Ask for my work brief") { store.ask("Search my connected work sources for open GitHub work, Jira issues assigned to me and recent Confluence documentation. Read relevant items before detailed claims. Summarize priorities, blockers and decisions with source links. State source limits and any errors; do not infer that all GitHub work is assigned to me.") }
                        .disabled(store.isThinking || (!store.demo && store.splashModel == nil))
                    Spacer()
                    if workspace.isSearching { ProgressView().controlSize(.small); Button("Stop") { workspace.cancel() } }
                }
                ForEach(WorkService.allCases) { service in if let error = workspace.errors[service] { Text("\(service.title): \(error)").font(.caption).foregroundStyle(.orange) } }
                ForEach(workspace.results, id: \.service) { result in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(result.service.title) · \(result.items.count) \(result.items.count == 1 ? "result" : "results")\(result.hasMore ? " · incomplete" : "")").font(.headline)
                        Text(result.scope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Fetched \(result.fetchedAt.formatted())").font(.caption2).foregroundStyle(.secondary)
                        if !workspace.currentQuery.isEmpty { Text("Search: \(workspace.currentQuery)").font(.caption).foregroundStyle(.secondary) }
                        ForEach(result.items) { item in
                            HStack(alignment: .top) {
                                Button { selected = item } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).fontWeight(.medium).multilineTextAlignment(.leading)
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                        if !item.excerpt.isEmpty { Text(item.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Link("Source", destination: item.url).font(.caption)
                            }.padding(.vertical, 7)
                        }
                        if !result.text.isEmpty { Text(result.text).font(.callout).textSelection(.enabled).lineLimit(12) }
                        if result.items.isEmpty && result.text.isEmpty { Text("No matching work in this bounded result.").foregroundStyle(.secondary) }
                    }.padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .sheet(item: $selected) { item in WorkItemDetailView(store: store, item: item) }
            .onChange(of: store.connectedWorkServices) { _, available in
                if provider != "all", !available.contains(where: { $0.rawValue == provider }) { provider = "all" }
            }
    }
    private func search() { workspace.search(query: query, services: services, github: store.githubConnector, atlassian: store.atlassianConnector) }
}

private struct WorkItemDetailView: View {
    @ObservedObject var store: PuddleStore
    let item: WorkItem
    @StateObject private var workspace = WorkSourcesWorkspace()
    @State private var view = "details"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(item.title).font(.title2).lineLimit(3); Spacer(); Button("Done") { dismiss() } }
            if item.service == .github && item.url.pathComponents.contains("pull") {
                Picker("View", selection: $view) { Text("Details").tag("details"); Text("Patch excerpts").tag("diff"); Text("Reported CI checks").tag("checks") }.pickerStyle(.segmented)
            }
            if workspace.isReading { ProgressView("Reading \(item.service.title)…") }
            if let error = workspace.errors[item.service] { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                if let result = workspace.detail {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(result.scope + (result.hasMore ? " Result is incomplete or shortened." : "")).font(.caption).foregroundStyle(.secondary)
                        Text("Fetched \(result.fetchedAt.formatted())").font(.caption2).foregroundStyle(.secondary)
                        Text(result.text).font(.system(size: 13, design: view == "diff" ? .monospaced : .default)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Link("Open original source", destination: item.url)
                Spacer()
                Button("Ask Puddle about this") {
                    store.ask("Read this connected work item before answering: service=\(item.service.rawValue), locator=\(item.locator), view=\(view). Summarize its requirements, current state, risks and next steps. Cite the source and distinguish evidence from assumptions. Mention missing content; do not change anything."); dismiss()
                }.buttonStyle(.borderedProminent).disabled(store.isThinking || store.splashModel == nil)
            }
        }.padding(26).frame(width: 720, height: 640)
            .task(id: view) { workspace.read(item, view: view, github: store.githubConnector, atlassian: store.atlassianConnector) }
            .onDisappear { workspace.cancel() }
            .onChange(of: store.atlassianConnection?.selectedSiteID) { _, _ in if item.service != .github { dismiss() } }
            .onChange(of: store.githubConnection) { _, _ in if item.service == .github { dismiss() } }
    }
}
