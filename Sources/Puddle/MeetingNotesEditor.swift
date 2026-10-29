import SwiftUI
import PuddleCore

struct MeetingNotesEditor: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: MeetingWorkspace
    let note: MeetingNote
    @State private var exporting = false
    private func text(_ key: WritableKeyPath<MeetingDraft, String>) -> Binding<String> {
        Binding(get: { workspace.draft(for: note)[keyPath: key] }, set: { value in workspace.edit(note) { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meeting notes").font(.headline)
                Spacer()
                Button("Export…") { exporting = true }
                Text(workspace.isDirty(note) ? "Unsaved changes" : "Saved locally").font(.caption).foregroundStyle(.secondary)
                Button("Save") { store.saveMeetingNote(note.id) }.buttonStyle(.borderedProminent).disabled(!workspace.isDirty(note))
                if workspace.isDirty(note) { Button("Discard changes") { workspace.discard(note.id) } }
            }
            TextField("Meeting title", text: text(\.title)).textFieldStyle(.roundedBorder)
            DatePicker("Meeting date", selection: Binding(get: { workspace.draft(for: note).meetingDate }, set: { date in workspace.edit(note) { $0.meetingDate = date } }))
            TextField("Participants", text: text(\.participants)).textFieldStyle(.roundedBorder)
            editor("Agenda", text: text(\.agenda), height: 80)
            editor("Your notes", text: text(\.notes), height: 180)
            MeetingCaptureView(store: store, capture: store.meetingCapture, note: note)
            if note.joinLink?.provider == .googleMeet || note.joinLink == nil {
                MeetAttendanceView(store: store, attendance: store.meetAttendance, note: note)
            }
            DisclosureGroup("Transcript") {
                HStack {
                    Button("Import transcript…") { store.chooseMeetingTranscript(note.id) }.disabled(workspace.isImporting || store.meetingCapture.isActive)
                    if workspace.isImporting { ProgressView().controlSize(.small); Button("Cancel import") { workspace.cancelImport() } }
                }
                if let error = workspace.importError { Text(error).font(.caption).foregroundStyle(.orange) }
                editor("Transcript text", text: text(\.transcript), height: 220)
                Text("Paste a transcript here. Meeting text is not used for automatic personal memory learning.").font(.caption).foregroundStyle(.secondary)
            }
            MeetingSummaryView(store: store, workspace: workspace, note: note)
            if let link = note.joinLink {
                Button("Open \(link.provider.title) join screen") { store.openMeetingLink(link.url.absoluteString) }.disabled(store.demo)
            }
            Text("Save changes before quitting. Drafts remain available when switching notes during this session.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .sheet(isPresented: $exporting) { MeetingExportSheet(store: store, note: note) }
    }
    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.body).frame(minHeight: height).padding(6)
                .background(PuddleStyle.background, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(title)
        }
    }
}
