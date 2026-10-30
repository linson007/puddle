import SwiftUI
import PuddleCore

struct CalendarView: View {
    @ObservedObject var store: PuddleStore
    @State private var range = CalendarRange.week
    @State private var query = ""
    @State private var selectedID: String?
    @State private var preparing: CalendarEvent?
    @State private var schedule = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let agenda = CalendarAgenda(events: store.state.calendarEvents, range: range, query: query, now: timeline.date)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if !store.calendarConnected {
                    GoogleWorkspaceConnectionView(store: store, title: "Calendar", icon: "calendar",
                        detail: "See your upcoming Google Calendar events, prepare for a meeting, and keep local notes.")
                } else if schedule {
                    CalendarScheduleView(store: store)
                } else {
                    HSplitView {
                        agendaList(agenda, now: timeline.date).frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
                        Group {
                            if let event = agenda.events.first(where: { $0.id == selectedID }) { eventDetail(event) }
                            else {
                                ContentUnavailableView("Select an event", systemImage: "calendar",
                                    description: Text("Choose an agenda item to see its details and meeting actions."))
                            }
                        }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onChange(of: agenda.events.map(\.id), initial: true) { _, ids in
                if !ids.contains(selectedID ?? "") { selectedID = ids.first }
            }
        }
        .sheet(item: $preparing) { MeetingPreparationView(store: store, event: $0) }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { heading; Spacer(minLength: 0); headerActions }
            VStack(alignment: .leading, spacing: 14) { heading; headerActions }
        }.padding(26)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Calendar").font(.system(size: 29, weight: .semibold, design: .rounded))
                .foregroundStyle(PuddleStyle.ink).accessibilityAddTraits(.isHeader)
            Text("Your agenda and the context for what’s next.").font(.callout).foregroundStyle(PuddleStyle.muted)
            if store.calendarConnected {
                Text("\(store.state.account ?? "Google Calendar") · Actions require review").font(.caption).foregroundStyle(PuddleStyle.muted)
                WorkspaceSyncStatus(date: store.state.calendarLastSync, isRefreshing: store.isRefreshingCalendar)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            if store.calendarConnected {
                Button(schedule ? "Agenda" : "Week & Month") { schedule.toggle() }
                    .buttonStyle(PuddleSecondaryButtonStyle())
                Button("New event") { store.proposeEvent() }.buttonStyle(PuddlePrimaryButtonStyle())
                Button { Task { await store.refreshCalendar() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(PuddleSecondaryButtonStyle())
                    .disabled(store.demo || store.isRefreshingCalendar || store.isSigningIn)
            }
        }
    }

    private func agendaList(_ agenda: CalendarAgenda, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Agenda range", selection: $range) {
                ForEach(CalendarRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            TextField("Search cached events", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search cached calendar events by title, location, or description")
            List(selection: $selectedID) {
                ForEach(agenda.days) { day in
                    Section {
                        ForEach(day.events) { event in eventRow(event, day: day.date).tag(event.id) }
                    } header: {
                        Text(Calendar.current.isDate(day.date, inSameDayAs: now) ? "Today" : day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    }
                }
                if !agenda.undated.isEmpty {
                    Section("Date unavailable") {
                        ForEach(agenda.undated) { event in eventRow(event, day: nil).tag(event.id) }
                    }
                }
            }.listStyle(.inset).scrollContentBackground(.hidden).background(PuddleStyle.panel)
                .overlay {
                    if agenda.events.isEmpty {
                        ContentUnavailableView {
                            Label(store.isRefreshingCalendar ? "Loading events…" : "No events in this view", systemImage: "calendar")
                        } description: {
                            Text(query.isEmpty ? "Refresh your calendar or choose another range." : "Try another title, location, or description.")
                        }
                    }
                }
            if store.state.calendarHasMore {
                Label("More events exist. This agenda is incomplete.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Primary Google calendar · Up to 50 cached events. Refresh loads the next 7 days. Times use \(TimeZone.current.identifier).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16)
    }

    private func eventRow(_ event: CalendarEvent, day: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title.isEmpty ? "Untitled event" : event.title).font(.callout.weight(.medium)).lineLimit(2)
            let continues = day.flatMap { day in AssistantDates.calendarDate(event.start).map { $0 < day } } ?? false
            Text(continues ? "Continues · \(CalendarAgenda.timeLabel(event))" : CalendarAgenda.timeLabel(event))
                .font(.caption).foregroundStyle(.secondary)
            if !event.location.isEmpty { Text(event.location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let link = event.joinLinks.first { Label(link.provider.title, systemImage: "video").font(.caption).foregroundStyle(PuddleStyle.teal) }
        }.padding(.vertical, 7)
    }

    private func eventDetail(_ event: CalendarEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(event.title.isEmpty ? "Untitled event" : event.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 10) {
                    Label(eventDate(event.start), systemImage: "calendar")
                    Text(CalendarAgenda.timeLabel(event)).font(.callout).foregroundStyle(.secondary)
                    if event.start.count == 10, let start = AssistantDates.calendarDate(event.start),
                       let end = AssistantDates.calendarDate(event.end),
                       let through = Calendar.current.date(byAdding: .day, value: -1, to: end), through > start {
                        Text("Through \(through.formatted(date: .complete, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    } else if event.start.count != 10, !event.end.isEmpty {
                        Text("Ends: \(eventDate(event.end))").font(.caption).foregroundStyle(.secondary)
                    }
                    if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").font(.callout).textSelection(.enabled) }
                }
                PuddleActionFlow { eventActions(event) }.frame(maxWidth: .infinity, alignment: .leading)
                if let status = store.meetingLinkStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let url = event.sourceURL { Link("Open in Google Calendar", destination: url).font(.callout).disabled(store.demo) }
                Divider()
                if !event.description.isEmpty {
                    Text("Event details").font(.headline)
                    Text(event.description).font(.body).lineSpacing(5).textSelection(.enabled)
                } else { Text("No description was provided for this event.").font(.callout).foregroundStyle(.secondary) }
                Text("Preparation and notes are saved in Puddle. Your Google Calendar event stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(PuddleStyle.panel.opacity(0.4)).id(event.id)
    }

    @ViewBuilder private func eventActions(_ event: CalendarEvent) -> some View {
        if event.etag != nil { Button("Edit Event…") { store.proposeEvent(event) } }
        if let link = event.joinLinks.first {
            Button("Join meeting") { store.openMeetingLink(link.url.absoluteString) }.disabled(store.demo)
        }
        Button("Prepare") { preparing = event }
        Button("Meeting notes") { store.createMeetingNote(event: event) }
    }

    private func eventDate(_ value: String) -> String {
        guard let date = AssistantDates.calendarDate(value) else { return value.isEmpty ? "Date unavailable" : value }
        return date.formatted(date: .complete, time: value.count == 10 ? .omitted : .shortened)
    }
}
