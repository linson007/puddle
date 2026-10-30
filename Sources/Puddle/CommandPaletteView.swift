import SwiftUI
import PuddleCore

struct CommandPaletteView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [WorkspaceSearchResult] = []
    @FocusState private var focused: Bool
    private var sections: [PuddleStore.Section] {
        PuddleStore.Section.allCases.filter { ($0 != .developer || store.state.profileLibrary.active.kind == .developer) && (query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search work or type a command…", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Search commands and saved workspace")
            Text("⌘K commands & search · ⌘⇧N quick capture · ⌘⇧L assistant panel").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if query.isEmpty || "new conversation".contains(query.lowercased()) { command("New conversation", icon: "square.and.pencil") { store.clearChat(); store.section = .chat } }
                    if query.isEmpty || "capture commitment".contains(query.lowercased()) { command("Capture a commitment", icon: "plus") { store.showQuickCapture = true } }
                    if query.isEmpty || "local ai setup splash".contains(query.lowercased()) { command("Set up local AI", icon: "desktopcomputer") { store.showLocalSetup = true } }
                    ForEach(sections, id: \.self) { section in command("Open \(section.rawValue)", icon: section.icon) { store.section = section } }
                    if !matches.isEmpty { Divider(); Text("Saved workspace · cached mail/calendar only").font(.caption).foregroundStyle(.secondary) }
                    ForEach(matches) { result in
                        Button {
                            dismiss()
                            // Present the destination after this sheet has closed.
                            Task { @MainActor in await Task.yield(); store.openSearchResult(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.callout.bold()).lineLimit(2)
                                Text(result.kind.rawValue.capitalized + " · " + result.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if !query.isEmpty, sections.isEmpty, matches.isEmpty { Text("No matches. Mail and calendar search here covers the local cache.").foregroundStyle(.secondary).padding() }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 650, height: 540).onAppear { focused = true }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let snapshot = store.state, query = query
                let work = Task.detached(priority: .userInitiated) { WorkspaceSearch.search(query, in: snapshot) }
                let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                if !Task.isCancelled { matches = found }
            }
    }
    private func command(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { dismiss(); Task { @MainActor in await Task.yield(); action() } } label: {
            Label(title, systemImage: icon).padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

extension PuddleStore {
    func openSearchResult(_ result: WorkspaceSearchResult) {
        switch result.kind {
        case .conversation: if let id = UUID(uuidString: result.locator) { openConversation(id) }
        case .task: section = .tasks; editingCommitment = state.tasks.first { $0.id.uuidString == result.locator }
        case .meeting: section = .meetings; meetingWorkspace.selectedID = UUID(uuidString: result.locator)
        case .email: section = .mail; selectedID = result.locator
        case .event: section = .calendar
        case .memory: section = .memory
        case .project: section = .portfolio; editingWorkProject = state.workProjects.first { $0.id.uuidString == result.locator }
        case .person: section = .portfolio; editingPerson = state.people.first { $0.id.uuidString == result.locator }
        case .decision: section = .portfolio; editingDecision = state.workDecisions.first { $0.id.uuidString == result.locator }
        case .document:
            section = .knowledge
            if let document = state.knowledgeDocuments.first(where: { $0.id.uuidString == result.locator }) { NSWorkspace.shared.open(document.url) }
        case .routine: section = .routines
        case .errand: section = .browser
        case .action:
            section = .actions
            if let action = state.actionProposals.first(where: { $0.id.uuidString == result.locator }), action.status == .draft { editingAction = action }
        }
    }
}
