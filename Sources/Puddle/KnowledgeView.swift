import SwiftUI
import PuddleCore

struct KnowledgeView: View {
    @ObservedObject var store: PuddleStore
    @State private var matches: [KnowledgePassage] = []
    @State private var removing: KnowledgeSource?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Knowledge").font(.largeTitle.bold()); Spacer(); Button("Add Files or Folder…") { store.chooseKnowledgeSources() }.disabled(store.knowledgeTask != nil || store.privateSession) }
                Text("Search selected local text, PDF, and DOCX documents. Indexing runs on this Mac without an AI model. Files stay read-only; imported text is reference material. Scanned PDFs need selectable text; OCR is not included.").font(.callout).foregroundStyle(.secondary)
                ForEach(store.state.knowledgeSources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(source.name).font(.headline); Text(source.status).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Refresh") { store.refreshKnowledge(source.id) }.disabled(store.knowledgeTask != nil)
                        Button("Remove…", role: .destructive) { removing = source }
                    }.padding(14).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.knowledgeTask != nil { HStack { ProgressView("Indexing local documents…").controlSize(.small); Button("Cancel") { store.knowledgeTask?.cancel() } } }
                TextField("Search your documents", text: $store.knowledgeSearchQuery).textFieldStyle(.roundedBorder)
                HStack {
                    Text("\(store.state.knowledgeDocuments.count) indexed documents · Up to 20 matching passages").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ask Puddle About Results") {
                        store.askReference(question: "Answer this question using the cited document passages: \(store.knowledgeSearchQuery)", reference: matches.map { "Source: \($0.title), line \($0.line) · \($0.url.path)\n\($0.quote)" }.joined(separator: "\n\n"), references: matches.map { SourceReference(title: "\($0.title):\($0.line)", url: $0.url) })
                    }.disabled(matches.isEmpty || store.isThinking)
                }
                ForEach(matches) { match in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Link(match.title, destination: match.url); Spacer(); Text("Extracted line \(match.line)").font(.caption).foregroundStyle(.secondary) }
                        Text(match.quote).font(.callout).textSelection(.enabled)
                        if match.limited { Label("This document was shortened during extraction.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.knowledgeSearchQuery.isEmpty {
                    ForEach(store.state.knowledgeDocuments.prefix(100)) { document in
                        HStack { Link(document.name, destination: document.url); Spacer(); Text(document.limited ? "Partial text" : "Indexed").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Up to 200 files and 10 million extracted characters per source; 200,000 characters per document, 200 PDF pages, and 25 MB per file. Hidden/private/generated folders and symbolic links are excluded. Refresh updates changed files and removes deleted entries. Indexes and folder grants stay on this Mac and are excluded from portable backups.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }.task(id: store.knowledgeSearchQuery + ":" + store.state.knowledgeDocuments.map { $0.sha256 }.joined()) {
            let documents = store.state.knowledgeDocuments, query = store.knowledgeSearchQuery
            let found = await Task.detached(priority: .userInitiated) { LocalKnowledge.search(query, documents: documents) }.value
            if !Task.isCancelled { matches = found }
        }.confirmationDialog("Remove this source and its indexed text?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Source", role: .destructive) { if let source = removing { store.removeKnowledgeSource(source.id) }; removing = nil }
        }
    }
}

extension PuddleStore {
    func chooseKnowledgeSources() {
        guard !privateSession, !isLocked else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "Choose local text, PDF, or DOCX files, or a folder to index. Hidden files and symbolic links are excluded."
        guard panel.runModal() == .OK else { return }
        do {
            let sources = try panel.urls.prefix(10).map(KnowledgeSource.init)
            guard state.knowledgeSources.count + sources.count <= 20 else { throw PuddleError("Connect up to 20 local sources.") }
            try commit { $0.knowledgeSources += sources }
            refreshKnowledgeSources(sources.map(\.id))
        } catch { fail(error) }
    }
    func refreshKnowledge(_ id: UUID) {
        refreshKnowledgeSources([id])
    }
    func refreshKnowledgeSources(_ ids: [UUID]) {
        guard knowledgeTask == nil, !privateSession, !isLocked else { return }
        let sources = state.knowledgeSources.filter { ids.contains($0.id) }
        knowledgeTask = Task {
            defer { knowledgeTask = nil }
            for source in sources {
                if Task.isCancelled || privateSession || isLocked { return }
                let previous = state.knowledgeDocuments.filter { $0.sourceID == source.id }
                let worker = Task.detached(priority: .userInitiated) { try LocalKnowledge.refresh(source, previous: previous) }
                do {
                    let (updated, documents) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation(); guard !privateSession, !isLocked else { return }
                    try commit { next in
                        if let index = next.knowledgeSources.firstIndex(where: { $0.id == source.id }) {
                            next.knowledgeSources[index] = updated; next.knowledgeDocuments.removeAll { $0.sourceID == source.id }; next.knowledgeDocuments += documents
                        }
                    }
                } catch is CancellationError { return } catch { fail(error) }
            }
        }
    }
    func removeKnowledgeSource(_ id: UUID) {
        knowledgeTask?.cancel()
        do { try commit { $0.knowledgeSources.removeAll { $0.id == id }; $0.knowledgeDocuments.removeAll { $0.sourceID == id } } } catch { fail(error) }
    }
}
