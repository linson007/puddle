import SwiftUI
import PuddleCore

struct CommandPaletteView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [WorkspaceSearchResult] = []
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool
    private struct Item: Identifiable {
        let id: String
        let title: String
        let icon: String?
        let result: WorkspaceSearchResult?
        let action: () -> Void
    }
    private var sections: [PuddleStore.Section] {
        PuddleStore.Section.allCases.filter { ($0 != .developer || store.state.profileLibrary.active.kind == .developer) && (query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query)) }
    }
    private var items: [Item] {
        var values: [Item] = []
        func command(_ id: String, _ title: String, _ terms: String, _ icon: String, _ action: @escaping () -> Void) {
            if query.isEmpty || terms.contains(query.lowercased()) {
                values.append(Item(id: id, title: title, icon: icon, result: nil, action: action))
            }
        }
        command("new", "New conversation", "new conversation", "square.and.pencil") { store.clearChat(); store.section = .chat }
        command("capture", "Capture a commitment", "capture commitment", "plus") { store.showQuickCapture = true }
        command("setup", "Set up local AI", "local ai setup splash", "desktopcomputer") { store.showLocalSetup = true }
        values += sections.map { section in
            Item(id: "section-" + section.rawValue, title: "Open " + section.rawValue, icon: section.icon, result: nil) { store.section = section }
        }
        values += matches.map { result in
            Item(id: "result-" + result.id, title: result.title, icon: nil, result: result) { store.openSearchResult(result) }
        }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search work or type a command…", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Search commands and saved workspace")
                .onSubmit { if items.indices.contains(selectedIndex) { activate(items[selectedIndex]) } }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            Text("⌘K commands & search · ⌘⇧N quick capture · ⌘⇧L assistant panel").font(.caption).foregroundStyle(.secondary)
            Text("↑↓ to select · Return to open · Esc to close").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if item.result?.id == matches.first?.id, item.result != nil {
                            Divider(); Text("Saved workspace · cached mail/calendar only").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { activate(item) } label: {
                            if let result = item.result {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.callout.bold()).lineLimit(2)
                                Text(result.kind.rawValue.capitalized + " · " + result.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            } else {
                                Label(item.title, systemImage: item.icon ?? "arrow.right").padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                        }.buttonStyle(.plain)
                            .background(selectedIndex == index ? PuddleStyle.inset : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
                            .id(item.id)
                    }
                    if !query.isEmpty, items.isEmpty { Text("No matches. Mail and calendar search here covers the local cache.").foregroundStyle(.secondary).padding() }
                }
            }.onChange(of: selectedIndex) { _, index in if items.indices.contains(index) { proxy.scrollTo(items[index].id) } } }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 650, height: 540).onAppear { focused = true }
            .onChange(of: query) { _, _ in selectedIndex = 0; matches = [] }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let snapshot = store.state, query = query
                let work = Task.detached(priority: .userInitiated) { WorkspaceSearch.search(query, in: snapshot) }
                let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                if !Task.isCancelled {
                    matches = found
                    selectedIndex = min(selectedIndex, max(0, items.count - 1))
                }
            }
    }
    private func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + offset))
    }
    private func activate(_ item: Item) {
        dismiss()
        // Present the destination after this sheet has closed.
        Task { @MainActor in await Task.yield(); item.action() }
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
