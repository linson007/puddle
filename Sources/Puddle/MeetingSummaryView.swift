import SwiftUI
import PuddleCore

struct MeetingSummaryView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: MeetingWorkspace
    let note: MeetingNote
    @State private var reviewingAction: MeetingAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local meeting summary").font(.headline)
                Spacer()
                if workspace.summarizingID == note.id {
                    ProgressView().controlSize(.small)
                    Button("Cancel summary") { store.cancelMeetingSummary() }
                } else {
                    Button(note.summary == nil ? "Generate summary" : "Regenerate summary") { store.generateMeetingSummary(note.id) }
                        .disabled(store.demo || workspace.summarizingID != nil || workspace.isDirty(note))
                }
            }
            if workspace.summarizingID == note.id { Text(workspace.summaryProgress).font(.caption).foregroundStyle(.secondary) }
            if let error = workspace.summaryError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let summary = note.summary {
                let draft = workspace.draft(for: note)
                if !summary.isCurrent(notes: draft.notes, transcript: draft.transcript) {
                    Label("Meeting text has changed. Save and regenerate to update these extracts.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Review these AI-selected source quotes. Classification can be mistaken; check the full transcript before acting.")
                    .font(.caption).foregroundStyle(.secondary)
                excerpts("Key points", summary.keyPoints)
                excerpts("Decisions", summary.decisions)
                if !summary.actions.isEmpty {
                    Text("Action items").font(.subheadline.weight(.semibold))
                    ForEach(summary.actions) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.quote).textSelection(.enabled)
                            Text("Owner: \(action.owner ?? "Not stated") · Timing: \(action.timing ?? "Not stated")").font(.caption).foregroundStyle(.secondary)
                            if let task = store.taskForMeetingAction(noteID: note.id, action: action) {
                                Button(task.completed ? "Task completed · View tasks" : "Task added · View tasks") { store.section = .tasks }.font(.caption)
                            } else {
                                Button("Review and add task…") { reviewingAction = action }
                                    .disabled(!summary.isCurrent(notes: draft.notes, transcript: draft.transcript))
                            }
                        }
                    }
                }
                excerpts("Open questions", summary.questions)
                if summary.keyPoints.isEmpty && summary.decisions.isEmpty && summary.actions.isEmpty && summary.questions.isEmpty {
                    Text("No supported extracts found. Your notes and transcript are unchanged.").foregroundStyle(.secondary)
                }
                Text("Generated \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(summary.model)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Save notes or a transcript, then extract key points, decisions, actions, and open questions using your local model. No tasks are created automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(PuddleStyle.background, in: RoundedRectangle(cornerRadius: 10))
            .sheet(item: $reviewingAction) { action in MeetingActionTaskSheet(store: store, note: note, action: action) }
    }
    @ViewBuilder private func excerpts(_ title: String, _ values: [MeetingExcerpt]) -> some View {
        if !values.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(values) { value in Text("“\(value.quote)”").textSelection(.enabled) }
        }
    }
}
