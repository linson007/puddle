import Combine
import Foundation
import PuddleCore

struct PendingTranscriptImport: Identifiable {
    let id = UUID()
    let noteID: UUID
    let result: ImportedTranscript
}

/// Unsaved drafts survive selection changes and failed saves within the running app.
@MainActor final class MeetingWorkspace: ObservableObject {
    @Published var selectedID: UUID?
    @Published private(set) var drafts: [UUID: MeetingDraft] = [:]
    @Published private(set) var status: String?
    @Published var pendingImport: PendingTranscriptImport?
    @Published private(set) var isImporting = false
    @Published private(set) var importError: String?
    @Published var summarizingID: UUID?
    @Published var summaryProgress = ""
    @Published var summaryError: String?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [MeetingSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var importingNoteID: UUID?
    private var importGeneration = UUID()
    private var importTask: Task<Void, Never>?

    func draft(for note: MeetingNote) -> MeetingDraft { drafts[note.id] ?? MeetingDraft(note) }
    func isDirty(_ note: MeetingNote) -> Bool { draft(for: note) != MeetingDraft(note) }
    func edit(_ note: MeetingNote, change: (inout MeetingDraft) -> Void) {
        var value = draft(for: note); change(&value)
        drafts[note.id] = value; status = nil
    }
    func saved(_ id: UUID) { drafts[id] = nil; status = "Saved locally." }
    func discard(_ id: UUID) { drafts[id] = nil; status = nil }
    func deleted(_ id: UUID) {
        discard(id); if selectedID == id { selectedID = nil }
        if importingNoteID == id || pendingImport?.noteID == id { cancelImport() }
    }

    func reset() {
        cancelImport(); drafts = [:]; selectedID = nil; status = nil
        summarizingID = nil; summaryProgress = ""; summaryError = nil
        searchGeneration = UUID(); searchTask?.cancel(); searchQuery = ""; searchResults = []; isSearching = false; searchError = nil
    }

    func updateSearch(notes: [MeetingNote]) {
        searchTask?.cancel(); searchGeneration = UUID(); let expected = searchGeneration
        searchError = nil
        let query = searchQuery, drafts = drafts
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchResults = []; isSearching = false; return }
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) { try MeetingSearch.results(notes: notes, drafts: drafts, query: query) }
                let results = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.searchGeneration == expected else { return }
                self.searchResults = results; self.isSearching = false
            } catch is CancellationError {}
            catch {
                guard let self, self.searchGeneration == expected else { return }
                self.searchResults = []; self.searchError = error.localizedDescription; self.isSearching = false
            }
        }
    }

    func importTranscript(from url: URL, into noteID: UUID) {
        cancelImport(); isImporting = true; importingNoteID = noteID
        let expected = importGeneration
        importTask = Task { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; if importGeneration == expected { isImporting = false } }
            do {
                try Task.checkCancellation()
                let reader = Task.detached(priority: .userInitiated) { try TranscriptImport.read(from: url) }
                let result = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                try Task.checkCancellation()
                guard importGeneration == expected else { return }
                pendingImport = PendingTranscriptImport(noteID: noteID, result: result)
            } catch is CancellationError {}
            catch { if importGeneration == expected { importError = error.localizedDescription } }
        }
    }
    func cancelImport(preservePreview: Bool = false) {
        importGeneration = UUID(); importTask?.cancel(); isImporting = false
        importingNoteID = nil; if !preservePreview { pendingImport = nil }; importError = nil
    }
}
