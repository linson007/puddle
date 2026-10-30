import SwiftUI
import PuddleCore

struct DeveloperView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: DeveloperWorkspace
    @State private var query = ""
    @State private var editingProject: DeveloperProject?
    @State private var removingProject = false
    @State private var deletingSession = false
    private var project: DeveloperProject? { store.state.activeDeveloperProject }
    private var sessions: [DevelopmentSession] {
        store.state.developmentSessions.filter { $0.projectID == nil || $0.projectID == project?.id }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        Group {
            if store.state.profileLibrary.active.kind != .developer {
                ContentUnavailableView {
                    Label("Developer workspace", systemImage: "chevron.left.forwardslash.chevron.right")
                } description: {
                    Text("Use the Developer profile to browse a local project, inspect changes and keep engineering context. Your personal workspace stays shared.")
                } actions: { Button("Use Developer Profile") { store.chooseDeveloperProfile() }.buttonStyle(.borderedProminent) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Developer workspace").font(.system(size: 29, weight: .semibold, design: .rounded))
                        Text("Bring source evidence, changes and debugging context into your local assistant.").foregroundStyle(.secondary)
                        WorkSourcesView(store: store, workspace: store.workSources)
                        projectCard
                        if let project {
                            HStack {
                                TextField("Find a path or search source text", text: $query).textFieldStyle(.roundedBorder)
                                    .onSubmit { workspace.inspect(.search(query), project: project) }
                                Button("Find Files") { workspace.inspect(.files(query), project: project) }
                                Button("Search Code") { workspace.inspect(.search(query), project: project) }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Git Status") { workspace.inspect(.status, project: project) }
                            }
                            if workspace.isInspecting {
                                HStack { ProgressView().controlSize(.small); Text("Inspecting local project…"); Spacer(); Button("Stop") { workspace.cancelInspection() } }
                            }
                            if let error = workspace.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                            if let result = workspace.inspection { inspection(result, project: project) }
                            HStack {
                                Button("Explain this project") { store.ask("Inspect the connected project with the available project tools. Start with its file list and relevant manifests or README, then explain its architecture and entry points. Cite files and lines, distinguish assumptions, and state any inspection limits.") }
                                Button("Review current changes") { store.ask("Read the connected project's Git status, then inspect relevant changed source and working/staged text diffs. Identify concrete bugs, regressions and missing verification with file/line evidence. State omitted paths and incomplete results. Do not claim tests ran or that files were changed.") }
                            }.disabled(store.isThinking || (!store.demo && store.splashModel == nil))
                        }
                        sessionPanel
                    }.frame(maxWidth: 960, alignment: .leading).padding(30).frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: project?.id) {
            workspace.cancelInspection()
            if let project, store.state.profileLibrary.active.kind == .developer, !store.demo { workspace.inspect(.files(""), project: project) }
        }
        .sheet(item: $editingProject) { ProjectContextEditor(store: store, project: $0) }
        .confirmationDialog("Remove this folder connection?", isPresented: $removingProject, titleVisibility: .visible) {
            Button("Remove Connection", role: .destructive) { if let project { store.removeDeveloperProject(project.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Project files are untouched. Saved development sessions remain available without a folder connection.") }
        .confirmationDialog("Delete this development session?", isPresented: $deletingSession, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) { if let id = workspace.selectedSessionID { store.deleteDevelopmentSession(id) } }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { workspace.cancelInspection() }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Connected project", systemImage: "folder").font(.headline)
                Spacer()
                Button(project == nil ? "Choose Folder…" : "Connect Folder…") { Task { await store.chooseDeveloperFolder() } }.disabled(store.demo)
            }
            if !store.state.developerProjects.isEmpty {
                Picker("Active project", selection: Binding(get: { store.state.activeDeveloperProjectID }, set: { store.selectDeveloperProject($0) })) {
                    Text("No project selected").tag(Optional<UUID>.none)
                    ForEach(store.state.developerProjects) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let project {
                Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !project.context.isEmpty { Text(project.context).font(.callout).textSelection(.enabled) }
                HStack {
                    Button("Edit Project Context") { editingProject = project }
                    Button("Reconnect Folder…") { Task { await store.chooseDeveloperFolder(reconnecting: project.id) } }.disabled(store.demo)
                    Button("Remove Connection…", role: .destructive) { removingProject = true }
                }
            } else { Text("Choose a project folder to enable source tools. You can keep development sessions without connecting files.").font(.callout).foregroundStyle(.secondary) }
            Text("Source access is read-only and stays on this Mac. Common private/generated paths, symlinks and recognized credential patterns are excluded; exclusions cannot identify every secret. Only source you request or the assistant reads is sent to your local model. Folder access is excluded from portable backups.")
                .font(.caption).foregroundStyle(.secondary)
        }.developerCard()
    }

    @ViewBuilder private func inspection(_ result: ProjectInspectionResult, project: DeveloperProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch result {
            case .files(let list):
                Text("Source files (\(list.files.count))").font(.headline)
                Text(list.scope).font(.caption).foregroundStyle(.secondary)
                if list.incomplete { Label("The file list is incomplete. Narrow the path filter.", systemImage: "info.circle").foregroundStyle(.orange) }
                ForEach(list.files) { file in
                    Button { workspace.inspect(.read(file.path, 1), project: project) } label: {
                        HStack { Text(file.path).font(.callout.monospaced()); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).padding(.vertical, 3)
                }
                if list.files.isEmpty { Text("No readable files match this path filter.").foregroundStyle(.secondary) }
            case .search(let result):
                Text("\(result.matches.count) matching lines · \(result.filesSearched) files searched").font(.headline)
                Text(result.scope).font(.caption).foregroundStyle(.secondary)
                if result.incomplete { Text("Search is incomplete; limits or excluded/unreadable files may hide matches.").foregroundStyle(.orange) }
                ForEach(result.matches) { match in
                    Button { workspace.inspect(.read(match.path, max(1, match.line - 3)), project: project) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(match.path):\(match.line)").font(.caption).foregroundStyle(PuddleStyle.teal)
                            Text(match.text).font(.callout.monospaced()).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            case .excerpt(let excerpt):
                Text("\(excerpt.path):\(excerpt.startLine)–\(excerpt.endLine)").font(.headline)
                code(excerpt.text)
                HStack {
                    if excerpt.startLine > 1 { Button("Previous lines") { workspace.inspect(.read(excerpt.path, max(1, excerpt.startLine - 120)), project: project) } }
                    if excerpt.endLine < excerpt.totalLines { Button("Next lines") { workspace.inspect(.read(excerpt.path, excerpt.endLine + 1), project: project) } }
                    Spacer()
                    Text("\(excerpt.totalLines) total lines\(excerpt.shortened ? " · excerpt only" : "")").font(.caption).foregroundStyle(.secondary)
                }
            case .status(let status):
                Text("\(status.branch) · \(status.commit)").font(.headline)
                Text("Checked \(status.checkedAt.formatted()) · codes: index / working tree · \(status.excluded) excluded paths").font(.caption).foregroundStyle(.secondary)
                if status.incomplete { Text("Git status is incomplete.").foregroundStyle(.orange) }
                ForEach(status.files) { file in
                    HStack {
                        Text(file.status).font(.callout.monospaced()).frame(width: 28)
                        Button(file.path) { workspace.inspect(.read(file.path, 1), project: project) }.buttonStyle(.link).font(.callout.monospaced())
                        Spacer()
                        Button("Working Diff") { workspace.inspect(.diff(file.path, false), project: project) }
                        Button("Staged Diff") { workspace.inspect(.diff(file.path, true), project: project) }
                    }
                }
                if status.files.isEmpty { Text("No changed paths in the readable source scope.").foregroundStyle(.secondary) }
            case .diff(let diff):
                Text("\(diff.staged ? "Staged" : "Working") text diff · \(diff.path)").font(.headline)
                Text(diff.scope).font(.caption).foregroundStyle(.secondary)
                if diff.shortened { Text("This diff was shortened at the output limit.").foregroundStyle(.orange) }
                code(diff.text)
            }
        }.developerCard()
    }
    private func code(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(minHeight: 120, maxHeight: 340).padding(12).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Development sessions", systemImage: "ladybug").font(.headline)
                Spacer()
                Menu("New Session") {
                    ForEach(DevelopmentSessionKind.allCases, id: \.self) { kind in Button(kind.title) { store.createDevelopmentSession(kind: kind) } }
                }
            }
            Text("Keep the problem, reproduction, findings and verification evidence together. Saved sessions are shared across role profiles; folders are connected separately.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Open session", selection: $workspace.selectedSessionID) {
                Text("Choose a session").tag(Optional<UUID>.none)
                ForEach(sessions) { Text($0.title + " · " + $0.status.title).tag(Optional($0.id)) }
            }
            if let session = sessions.first(where: { $0.id == workspace.selectedSessionID }) {
                DevelopmentSessionEditor(store: store, workspace: workspace, session: session, onDelete: { deletingSession = true })
            } else if sessions.isEmpty { Text("Start a debugging, implementation or review session. No model or folder is required to save your notes.").foregroundStyle(.secondary) }
        }.developerCard()
    }
}

private struct ProjectContextEditor: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeveloperProject
    init(store: PuddleStore, project: DeveloperProject) { self.store = store; _draft = State(initialValue: project) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Project context").font(.title2)
            TextField("Project name", text: $draft.name).textFieldStyle(.roundedBorder)
            TextField("Stack, architecture, goals and constraints", text: $draft.context, axis: .vertical).lineLimit(5...10).textFieldStyle(.roundedBorder)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save Context") { if store.saveDeveloperProject(draft) { dismiss() } }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 520)
    }
}

private struct DevelopmentSessionEditor: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: DeveloperWorkspace
    let session: DevelopmentSession
    var onDelete: () -> Void
    private func binding<Value>(_ key: WritableKeyPath<DevelopmentSession, Value>) -> Binding<Value> {
        Binding(get: { workspace.draft(session)[keyPath: key] }, set: { value in workspace.edit(session) { $0[keyPath: key] = value } })
    }
    var body: some View {
        let draft = workspace.draft(session)
        VStack(alignment: .leading, spacing: 14) {
            TextField("Session title", text: binding(\.title)).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Type", selection: binding(\.kind)) { ForEach(DevelopmentSessionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Status", selection: binding(\.status)) { ForEach(DevelopmentSessionStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Picker("Project", selection: binding(\.projectID)) {
                Text("No folder connection").tag(Optional<UUID>.none)
                ForEach(store.state.developerProjects) { Text($0.name).tag(Optional($0.id)) }
            }
            if draft.projectID == nil, let name = draft.projectName { Text("Previous project: \(name). Connect a folder and select it above to restore source access.").font(.caption).foregroundStyle(.secondary) }
            field("Problem / objective", key: \.problem)
            field("Expected behavior", key: \.expected)
            field("Observed behavior / errors", key: \.observed)
            field("Reproduction steps", key: \.reproduction)
            field("Findings, decisions and resolution", key: \.findings)
            field("Verification plan and observed results", key: \.verification)
            Text("Verification is user-recorded evidence. Puddle does not run project code or tests.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save Session") { store.saveDevelopmentSession(draft) }.buttonStyle(.borderedProminent)
                Button("Save & Ask Puddle") {
                    if store.saveDevelopmentSession(draft) {
                        if let id = draft.projectID, !store.selectDeveloperProject(id) { return }
                        store.ask(draft.question)
                    }
                }.disabled(store.isThinking || (!store.demo && store.splashModel == nil))
                if draft != session { Button("Discard Draft") { workspace.saved(session.id) } }
                Spacer()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
    }
    private func field(_ label: String, key: WritableKeyPath<DevelopmentSession, String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: binding(key), axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}

private extension View {
    func developerCard() -> some View { padding(20).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12)) }
}
