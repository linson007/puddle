import SwiftUI
import PuddleCore

struct MeetingPreparationView: View {
    @ObservedObject var store: PuddleStore
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let preparation = MeetingPreparation(event: event, snapshot: store.state)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meeting preparation").font(.caption).foregroundStyle(.secondary)
                    Text(event.title).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Calendar updated: \(store.state.calendarLastSync?.formatted() ?? "not refreshed"). Saved notes and actions are local reference material.")
                .font(.caption).foregroundStyle(.secondary)
            if event.seriesID != nil { Label("Recurring series: linked notes are included even when the event title changes.", systemImage: "repeat").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Before you join").font(.headline)
                        Label(ExecutiveBrief.eventDate(event.start)?.formatted(date: .complete, time: event.start.count == 10 ? .omitted : .shortened) ?? event.start, systemImage: "calendar")
                        if !event.location.isEmpty { Text(event.location).font(.callout).textSelection(.enabled) }
                        if !event.description.isEmpty {
                            DisclosureGroup("Calendar description") { Text(event.description).font(.callout).textSelection(.enabled) }
                        }
                        HStack {
                            if let url = event.sourceURL { Link("Open calendar source", destination: url) }
                            if let link = event.joinLinks.first { Button("Join meeting") { store.openMeetingLink(link.url.absoluteString) }.disabled(store.demo) }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Open actions from related notes (\(preparation.actions.count))").font(.headline)
                        if preparation.actions.isEmpty { Text("No open actions linked to these notes.").foregroundStyle(.secondary) }
                        ForEach(preparation.actions) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).fontWeight(.medium)
                                if !task.owner.isEmpty { Text("\(task.workflow == .waiting ? "Waiting on" : "Owner:") \(task.owner)").font(.caption).foregroundStyle(.secondary) }
                                if let source = task.meetingSource { Text("“\(source.quote)”").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saved context (\(preparation.notes.count))").font(.headline)
                        Text("Matched by calendar event ID or the same full meeting title. Review the dates before relying on earlier notes.")
                            .font(.caption).foregroundStyle(.secondary)
                        if preparation.notes.isEmpty { Text("No matching notes yet. Start with the outcome you need and the decisions to make.").foregroundStyle(.secondary) }
                        ForEach(preparation.notes.prefix(8)) { note in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { store.meetingWorkspace.selectedID = note.id; store.section = .meetings; dismiss() } label: {
                                    Label(note.meetingDate.formatted(date: .abbreviated, time: .shortened), systemImage: "doc.text")
                                }.buttonStyle(.link)
                                if !note.agenda.isEmpty { Text("Agenda: \(note.agenda)").font(.callout).textSelection(.enabled) }
                                if let summary = note.summary, summary.isCurrent(notes: note.notes, transcript: note.transcript) {
                                    ForEach(summary.decisions.prefix(5)) { decision in
                                        Text("Decision: “\(decision.quote)”").font(.callout).textSelection(.enabled)
                                    }
                                    ForEach(summary.questions.prefix(5)) { question in
                                        Text("Open question: “\(question.quote)”").font(.callout).textSelection(.enabled)
                                    }
                                } else if note.summary != nil {
                                    Text("The source text changed after extraction. Regenerate its summary in Meetings before using earlier decisions.")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(PuddleStyle.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if preparation.notes.count > 8 { Text("Showing the eight most recent notes. Find earlier notes in Meetings.").font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button("Open meeting workspace") {
                if store.createMeetingNote(event: event) != nil { dismiss() }
            }.buttonStyle(.borderedProminent)
        }.padding(26).frame(width: 680, height: 650)
    }
}
