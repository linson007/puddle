import SwiftUI
import PuddleCore

struct ActionsView: View {
    @ObservedObject var store: PuddleStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Actions").font(.largeTitle.bold())
                Text("Review drafts and inspect what happened. An interrupted action never replays automatically.").foregroundStyle(.secondary)
                HStack { Button("Compose email") { store.composeMail() }; Button("Propose event") { store.proposeEvent() } }
                if store.state.actionProposals.isEmpty { ContentUnavailableView("No actions yet", systemImage: "tray", description: Text("Compose an email or propose an event. You review the exact contents before anything changes.")) }
                ForEach(store.state.actionProposals) { action in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(action.title).font(.headline)
                            Spacer(); Text(action.status.rawValue.capitalized).font(.caption).foregroundStyle(action.status == .uncertain ? .orange : .secondary)
                        }
                        Text(action.account).font(.caption).foregroundStyle(.secondary)
                        if let originalID = action.undoOf, let original = store.state.actionProposals.first(where: { $0.id == originalID }) {
                            Text("Reviewed undo of: \(original.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let detail = action.detail { Text(detail).font(.callout).textSelection(.enabled) }
                        HStack {
                            if action.status == .draft {
                                Button("Edit & Review") { store.editingAction = action }
                                Button("Discard draft", role: .destructive) { store.discardAction(action.id) }
                            }
                            if store.executingActions.contains(action.id) { ProgressView().controlSize(.small) }
                            if store.canUndoCalendarAction(action) { Button("Review Undo…") { store.proposeCalendarUndo(action) } }
                            if let url = action.resultURL ?? action.sourceURL { Link("Open source", destination: url) }
                        }
                    }.padding(18).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct ActionEditorView: View {
    @ObservedObject var store: PuddleStore
    let initial: ActionProposal
    @Environment(\.dismiss) private var dismiss
    @State private var mail: MailDraft
    @State private var event: CalendarDraft
    @State private var account: String
    @State private var reviewing = false
    @State private var instructions = "Draft a concise, helpful reply. Ask about missing facts rather than inventing them."
    @State private var generating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var error: String?
    init(store: PuddleStore, initial: ActionProposal) {
        self.store = store; self.initial = initial
        _account = State(initialValue: initial.account.isEmpty ? store.accountForAction(initial) ?? "" : initial.account)
        if case .email(let value) = initial.payload { _mail = State(initialValue: value) } else { _mail = State(initialValue: MailDraft()) }
        if case .calendar(let value) = initial.payload { _event = State(initialValue: value) } else { _event = State(initialValue: CalendarDraft()) }
    }
    private var proposal: ActionProposal {
        var result = initial
        result.account = account
        switch initial.payload { case .email: result.payload = .email(mail); case .calendar: result.payload = .calendar(event); case .mailLabels, .unsubscribe, .calendarRemoval: break }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reviewing ? "Review this action" : "Prepare an action").font(.title2.bold())
            Text("Account: \(account.isEmpty ? (initial.provider == .outlook ? "Connect Outlook before sending" : "Connect Google before sending or booking") : account)").font(.callout).foregroundStyle(.secondary)
            if !reviewing, let connected = store.accountForAction(initial), connected != account {
                Button("Use connected account: \(connected)") { account = connected }
            }
            ScrollView {
                if reviewing { review }
                else {
                    switch initial.payload {
                    case .email: mailEditor
                    case .calendar: calendarEditor
                    case .mailLabels, .unsubscribe, .calendarRemoval: review
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let message = store.errorMessage { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                if !reviewing { Button("Save Draft") { if store.saveAction(proposal) { dismiss() } } }
                Spacer()
                if reviewing {
                    Button("Back to Edit") { reviewing = false }
                    Button(executeTitle) {
                        let reviewed = proposal
                        if store.saveAction(reviewed) {
                            dismiss(); store.section = .actions
                            Task { await store.executeAction(reviewed.id, reviewedDigest: reviewed.digest) }
                        }
                    }.buttonStyle(.borderedProminent).disabled(store.demo || account.isEmpty)
                } else {
                    Button("Review Exact Contents") {
                        do { var candidate = proposal; try candidate.authorize(digest: candidate.digest); error = nil; reviewing = true }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(generating)
                }
            }
        }.padding(24).frame(width: 720, height: 700).tint(PuddleStyle.teal)
            .onDisappear { generationTask?.cancel() }
    }
    private var executeTitle: String {
        switch initial.payload { case .email: return "Send This Email"; case .calendar: return event.eventID == nil ? "Create This Event" : "Update This Event"; case .mailLabels: return "Apply These Labels"; case .unsubscribe: return "Unsubscribe This Sender"; case .calendarRemoval: return "Delete This Event" }
    }
    private var mailEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("To: comma-separated addresses", text: $mail.to).textFieldStyle(.roundedBorder)
            TextField("Cc", text: $mail.cc).textFieldStyle(.roundedBorder)
            TextField("Subject", text: $mail.subject).textFieldStyle(.roundedBorder)
            TextEditor(text: $mail.body).font(.body).frame(minHeight: 190).accessibilityLabel("Email body")
            Toggle("Remind me to follow up", isOn: Binding(get: { mail.followUpAt != nil }, set: { mail.followUpAt = $0 ? Date().addingTimeInterval(86400) : nil }))
            if mail.followUpAt != nil { DatePicker("Follow-up reminder", selection: Binding(get: { mail.followUpAt ?? Date() }, set: { mail.followUpAt = $0 })) }
            Divider()
            TextField("Instructions for the local model", text: $instructions).textFieldStyle(.roundedBorder)
            HStack {
                Button(generating ? "Drafting…" : "Draft with Puddle") {
                    generating = true; error = nil; let before = proposal
                    generationTask = Task {
                        defer { generating = false }
                        do {
                            let body = try await store.generateMailDraft(before, instructions: instructions)
                            guard !Task.isCancelled else { return }
                            guard proposal.digest == before.digest else { error = "The draft changed while generating. Your edits were preserved."; return }
                            mail.body = body
                        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                }.disabled(generating || store.demo)
                if generating { ProgressView().controlSize(.small); Button("Stop drafting") { generationTask?.cancel() } }
            }
            Text("Generated text stays editable. Sending happens only after reviewing recipients and the complete message.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var calendarEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Event title", text: $event.title).textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: $event.start)
            DatePicker("Ends", selection: $event.end)
            TextField("Timezone", text: $event.timezone).textFieldStyle(.roundedBorder)
            TextField("Calendar ID", text: $event.calendarID).textFieldStyle(.roundedBorder)
            TextField("Attendee email addresses", text: $event.attendees).textFieldStyle(.roundedBorder)
            TextField("Location", text: $event.location).textFieldStyle(.roundedBorder)
            TextEditor(text: $event.notes).frame(minHeight: 120).accessibilityLabel("Event description")
            Text("Calendar changes send updates to attendees. Existing events are protected against overwriting a newer version.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch proposal.payload {
            case .email(let draft):
                Text("To: \(draft.to)"); if !draft.cc.isEmpty { Text("Cc: \(draft.cc)") }
                Text("Subject: \(draft.subject)").font(.headline)
                Divider(); Text(draft.body).textSelection(.enabled)
                if let date = draft.followUpAt { Text("Local follow-up: \(date.formatted())").font(.caption) }
            case .calendar(let draft):
                Text(draft.title).font(.headline)
                Text("\(draft.start.formatted()) → \(draft.end.formatted())")
                Text("Event timezone: \(draft.timezone). Times above use your Mac’s timezone.")
                Text("Calendar: \(draft.calendarID)\nAttendees: \(draft.attendees)\nLocation: \(draft.location)")
                Text(draft.notes).textSelection(.enabled)
                Text("Attendees will receive event notifications.").foregroundStyle(.orange)
            case .mailLabels(let id, let add, let remove):
                Text("Message: \(id)").font(.headline)
                Text("Add: \(add.joined(separator: ", "))\nRemove: \(remove.joined(separator: ", "))")
            case .unsubscribe(let target):
                Text("Sender: \(target.sender)").font(.headline)
                Text("POST " + target.url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                Text("Request body: List-Unsubscribe=One-Click").font(.caption)
                Text("No provider credentials or browser cookies are sent. This changes your subscription with the sender.").font(.callout).foregroundStyle(.secondary)
            case .calendarRemoval(let value):
                Text("Delete: \(value.title)").font(.headline)
                Text("\(value.start.formatted()) → \(value.end.formatted())\nCalendar: \(value.calendarID)\nEvent: \(value.eventID)")
                Text("Attendees receive cancellation updates. The provider will reject this undo if the event has changed since the recorded action.").foregroundStyle(.orange)
            }
            if let url = proposal.sourceURL { Link("Review original source", destination: url) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }
}
