import SwiftUI
import PuddleCore

struct MeetingActionTaskSheet: View {
    @ObservedObject var store: PuddleStore
    let note: MeetingNote
    let action: MeetingAction
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var owner: String
    @State private var workflow = TaskWorkflow.active
    @State private var dated = false
    @State private var due = Date().addingTimeInterval(3600)
    init(store: PuddleStore, note: MeetingNote, action: MeetingAction) {
        self.store = store; self.note = note; self.action = action
        _title = State(initialValue: String(action.quote.prefix(300)))
        _owner = State(initialValue: action.owner ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add meeting action as a task").font(.title2)
            Text(note.title).font(.headline)
            ScrollView { Text("“\(action.quote)”").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
            Text("Owner: \(action.owner ?? "Not stated") · Timing in source: \(action.timing ?? "Not stated")").font(.caption).foregroundStyle(.secondary)
            TextField("Task title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Owner (review before saving)", text: $owner).textFieldStyle(.roundedBorder)
            Picker("Track as", selection: $workflow) {
                ForEach(TaskWorkflow.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if action.quote.count > 300 { Text("The suggested title was shortened to 300 characters. Edit it before adding.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Set a reminder time", isOn: $dated)
            if dated { DatePicker("Remind me", selection: $due, in: Date()...) }
            Text("Relative dates are not guessed. Review ownership and choose a time yourself. This creates a local task.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Add task") {
                    if store.createTaskFromMeeting(noteID: note.id, actionID: action.id, title: title, dueAt: dated ? due : nil, owner: owner, workflow: workflow) != nil { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 300)
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(24).frame(width: 480)
    }
}
