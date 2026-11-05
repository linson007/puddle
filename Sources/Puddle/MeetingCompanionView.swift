import SwiftUI
import AppKit
import PuddleCore

struct MeetingCompanionView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var capture: MeetingCaptureController
    @ObservedObject var workspace: MeetingWorkspace
    @State private var source = MeetingAudioSource.both
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isLocked { PrivacyLockView(store: store) }
            else if let note = store.state.meetings.first(where: { $0.id == store.companionNoteID }) {
                Text(note.title).font(.title3.bold())
                Label(capture.isActive ? capture.message : "Local meeting notes", systemImage: capture.isActive ? "record.circle.fill" : "lock.shield")
                    .font(.caption).foregroundStyle(capture.isActive ? .red : .secondary)
                if capture.noteID == note.id, capture.isActive {
                    Button(L10n.text("Stop & Save Transcript")) { store.saveCaptureOnCompletion = note.id; capture.stop() }.buttonStyle(.borderedProminent)
                    ScrollViewReader { proxy in
                        ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(capture.timeline.segments) { segment in
                                Text("\(MeetingTranscriptTimeline.timestamp(segment.start)) · \(segment.channel.title)\n\(segment.text)").font(.callout).textSelection(.enabled).id(segment.id)
                            }
                        } }
                        .onChange(of: capture.timeline.segments.last?.text) { _, _ in if let id = capture.timeline.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                } else {
                    Picker(L10n.text("Audio source"), selection: $source) { ForEach(MeetingAudioSource.allCases) { Text($0.title).tag($0) } }
                    Button(L10n.text("Start Local Transcription")) { store.startMeetingTranscription(note.id, source: source) }
                        .disabled(!store.canStartMeetingTranscription(note.id))
                    if let reason = store.meetingTranscriptionBlockedReason(note.id) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    TextField(L10n.text("Search transcript"), text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        Text(query.isEmpty ? note.transcript : note.transcript.components(separatedBy: "\n\n").filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n\n"))
                            .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.state.meetingCaptureRecoveries.contains(where: { $0.noteID == note.id }) {
                        Button(L10n.text("Review Recovered Transcript")) { store.reviewMeetingCapture(note.id); store.section = .meetings }
                    }
                    Button(L10n.text("Generate Summary")) { store.generateMeetingSummary(note.id) }.disabled(workspace.summarizingID != nil || note.transcript.isEmpty)
                    if workspace.summarizingID == note.id { ProgressView(workspace.summaryProgress).controlSize(.small) }
                    if let error = workspace.summaryError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                TextEditor(text: Binding(get: { workspace.draft(for: note).notes }, set: { value in workspace.edit(note) { $0.notes = value } }))
                    .frame(minHeight: 80, maxHeight: 130).accessibilityLabel(L10n.text("Quick meeting notes"))
                Button(L10n.text("Save Notes")) { Task { _ = await store.saveMeetingNote(note.id) } }.disabled(!workspace.isDirty(note))
                Text("Tell participants before transcribing. Captured text is checkpointed locally; raw audio is not saved.").font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView(L10n.text("Choose meeting notes"), systemImage: "note.text", description: Text("Open Companion from a meeting note.")) }
            if !store.isLocked, let error = capture.errorMessage ?? store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(16).frame(minWidth: 350, minHeight: 430).background(FloatingMeetingWindow())
            .onAppear { store.meetingCompanionVisible = true }
            .onDisappear { store.meetingCompanionVisible = false; if capture.noteID == store.companionNoteID { capture.stop() } }
    }
}
private struct FloatingMeetingWindow: NSViewRepresentable {
    final class Host: NSView { override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.level = .floating } }
    func makeNSView(context: Context) -> NSView { Host() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension PuddleStore {
    func checkpointMeetingCapture(_ id: UUID, text: String, capturedAt: Date = Date()) async {
        guard !demo, !privateSession, storageAvailable, !text.isEmpty, state.meetings.contains(where: { $0.id == id }) else { return }
        guard !Task.isCancelled, capturedAt > (state.meetingRecoveryDismissals[id] ?? .distantPast) else { return }
        let text = String(text.prefix(200_000))
        guard state.meetingCaptureRecoveries.first(where: { $0.noteID == id })?.text != text else { return }
        var values = state.meetingCaptureRecoveries.filter { $0.noteID != id }
        values.append(MeetingCaptureRecovery(noteID: id, text: text, updatedAt: capturedAt))
        do { try await checkpointRecoveries(values) }
        catch { fail(error) }
    }

    func reviewMeetingCapture(_ id: UUID) {
        guard let recovery = state.meetingCaptureRecoveries.first(where: { $0.noteID == id }) else { return }
        if meetingCapture.noteID == id { meetingCapture.stopImmediately() }
        meetingWorkspace.selectedID = id
        meetingWorkspace.pendingImport = PendingTranscriptImport(noteID: id, result: ImportedTranscript(text: recovery.text, sourceName: "Recovered local capture"), recovery: recovery)
    }
    func discardMeetingCapture(_ id: UUID) async {
        do {
            if meetingCapture.noteID == id { meetingCapture.stopImmediately() }
            try await commit { $0.meetingCaptureRecoveries.removeAll { $0.noteID == id }; $0.meetingRecoveryDismissals[id] = Date() }
            try await removeObsoleteMeetingRecoveries()
        } catch { fail(error) }
    }
    func removeObsoleteMeetingRecoveries() async throws {
        guard !demo, !privateSession else { return }
        try await checkpointRecoveries(state.meetingCaptureRecoveries)
    }
}
