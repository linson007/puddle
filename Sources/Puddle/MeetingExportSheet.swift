import SwiftUI
import PuddleCore

struct MeetingExportSheet: View {
    @ObservedObject var store: PuddleStore
    let note: MeetingNote
    @Environment(\.dismiss) private var dismiss
    @State private var format = MeetingExportFormat.markdown
    @State private var includeTranscript = true
    @State private var includeJoinLink = false
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export meeting notes").font(.title2)
            Text(store.meetingWorkspace.draft(for: note).title).font(.headline)
            Picker("Format", selection: $format) { ForEach(MeetingExportFormat.allCases) { Text($0.title).tag($0) } }
            if format != .transcript {
                Toggle("Include full transcript", isOn: $includeTranscript)
                if note.joinLink != nil { Toggle("Include meeting join link", isOn: $includeJoinLink) }
                Text("Summaries include their source quotes even when the full transcript is excluded.").font(.caption).foregroundStyle(.secondary)
            }
            if store.meetingWorkspace.isDirty(note) { Label("Exports your current unsaved draft. The saved note is unchanged.", systemImage: "pencil").font(.caption).foregroundStyle(.secondary) }
            Text("Choose where to save the file. Puddle does not upload or send the export.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.disabled(exporting)
                Button("Export…") {
                    exporting = true; error = nil
                    Task { @MainActor in
                        defer { exporting = false }
                        do {
                            if try await store.exportMeetingNote(note.id, format: format, includeTranscript: includeTranscript, includeJoinLink: includeJoinLink) { dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(exporting)
            }
        }.padding(24).frame(width: 470)
    }
}
