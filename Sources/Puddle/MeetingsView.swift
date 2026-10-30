import SwiftUI
import PuddleCore

struct MeetingsView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var workspace: MeetingWorkspace
    @State private var address = ""
    @State private var preparing: CalendarEvent?
    private var meetings: [CalendarEvent] { store.state.calendarEvents.filter {
        !$0.joinLinks.isEmpty && (ExecutiveBrief.eventDate($0.end) ?? ExecutiveBrief.eventDate($0.start) ?? .distantPast) >= Date()
    } }
    private var joinLink: MeetingJoinLink? { try? MeetingJoinLink(address) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Meetings").font(.system(size: 29, weight: .semibold, design: .rounded))
                    .foregroundStyle(PuddleStyle.ink).accessibilityAddTraits(.isHeader)
                Text("Open a meeting from your calendar or paste an invitation link.").font(.callout).foregroundStyle(PuddleStyle.muted)
                joinCard
                if workspace.selectedID == nil { MeetAttendanceView(store: store, attendance: store.meetAttendance, invitation: $address) }
                HStack {
                    Text("Your meeting notes").font(.headline)
                    Spacer(); Button("New notes") { store.createMeetingNote() }.buttonStyle(PuddlePrimaryButtonStyle())
                }
                if !store.state.meetings.isEmpty {
                    TextField("Search meeting titles, notes, transcripts, and actions", text: $workspace.searchQuery).textFieldStyle(.roundedBorder)
                    if !workspace.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if workspace.isSearching { ProgressView("Searching meetings…").controlSize(.small) }
                        else if let error = workspace.searchError { Text(error).font(.caption).foregroundStyle(.orange) }
                        else if workspace.searchResults.isEmpty { Text("No meeting notes match this search.").font(.callout).foregroundStyle(.secondary) }
                        else {
                            Text("\(workspace.searchResults.count) matching meetings").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(workspace.searchResults) { result in
                                        Button { workspace.selectedID = result.id } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(result.title + (result.hasUnsavedChanges ? " · Unsaved" : "")).font(.headline)
                                                Text("\(result.field): \(result.snippet)").font(.caption).lineLimit(3).foregroundStyle(.secondary)
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        }.buttonStyle(.plain).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                                            .accessibilityLabel("Open meeting notes: \(result.title)")
                                    }
                                }
                            }.frame(maxHeight: 240)
                        }
                    }
                    Picker("Open notes", selection: $workspace.selectedID) {
                        Text("Choose meeting notes").tag(Optional<UUID>.none)
                        ForEach(store.state.meetings.sorted { $0.updatedAt > $1.updatedAt }) { note in
                            Text(note.title + (workspace.isDirty(note) ? " · Unsaved" : "")).tag(Optional(note.id))
                        }
                    }
                }
                if let selected = store.state.meetings.first(where: { $0.id == workspace.selectedID }) {
                    MeetingNotesEditor(store: store, workspace: workspace, note: selected).id(selected.id)
                } else if store.state.meetings.isEmpty {
                    Text("Keep an agenda, notes, and a transcript locally. Start from New notes or a calendar event.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Upcoming meetings").font(.headline)
                    Spacer()
                    if store.calendarConnected {
                        Button("Refresh calendar") { Task { await store.refreshCalendar() } }.disabled(store.demo || store.isRefreshingCalendar)
                    } else { Button("Connect Calendar") { store.section = .calendar } }
                }
                ForEach(meetings) { event in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.title).font(.headline)
                        Text(AssistantDates.parse(event.start)?.formatted(date: .abbreviated, time: .shortened) ?? event.start)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Prepare") { preparing = event }
                            Button("Notes") { store.createMeetingNote(event: event) }
                            if let link = event.joinLinks.first {
                                Label(link.provider.title, systemImage: "video").font(.caption)
                                Spacer()
                                Button("Open join screen") { store.openMeetingLink(link.url.absoluteString) }.disabled(store.demo)
                            }
                            if let url = event.sourceURL { Link("View event", destination: url) }
                        }
                    }.meetingCard()
                }
                if meetings.isEmpty { Text("No supported meeting links in the cached calendar. Refresh Calendar or paste a link above.").font(.callout).foregroundStyle(.secondary) }
                if store.state.calendarHasMore { Text("More calendar events exist. Ask Puddle for a shorter calendar window.").font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: 760, alignment: .leading).padding(30).frame(maxWidth: .infinity)
        }.sheet(item: $preparing) { MeetingPreparationView(store: store, event: $0) }
            .sheet(item: $workspace.pendingImport) { pending in TranscriptImportSheet(store: store, pending: pending) }
            .onDisappear { store.meetingCapture.stop(); workspace.cancelImport(preservePreview: true) }
            .onChange(of: workspace.searchQuery) { _, _ in workspace.updateSearch(notes: store.state.meetings) }
            .onChange(of: workspace.drafts) { _, _ in workspace.updateSearch(notes: store.state.meetings) }
            .onChange(of: store.state.meetings) { _, _ in workspace.updateSearch(notes: store.state.meetings) }
            .onAppear { workspace.updateSearch(notes: store.state.meetings) }
    }

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a meeting").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                TextField("Google Meet, Zoom, Teams, or Webex join link", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Meeting invitation link")
                    .onSubmit { if joinLink != nil && !store.demo { store.openMeetingLink(address) } }
                Button("Open join screen") { store.openMeetingLink(address) }
                    .buttonStyle(PuddlePrimaryButtonStyle())
                    .disabled(store.demo || joinLink == nil)
                    .fixedSize()
            }
            if let link = joinLink {
                Label(link.provider.title, systemImage: "video").font(.caption)
            } else if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Paste a complete HTTPS meeting invitation link from Google Meet, Zoom, Microsoft Teams, or Webex.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.demo {
                Text("Exit Demo mode to open a meeting.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Open the join screen to choose your camera, microphone, and when to join. For automated Google Meet attendance, use the controls below.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = store.meetingLinkStatus { Text(status).font(.callout).foregroundStyle(PuddleStyle.teal) }
        }.meetingCard()
    }

}

private extension View {
    func meetingCard() -> some View {
        puddleCard()
    }
}
