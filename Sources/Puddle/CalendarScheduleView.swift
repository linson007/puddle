import SwiftUI
import PuddleCore

struct CalendarScheduleView: View {
    @ObservedObject var store: PuddleStore
    @State private var anchor = Date()
    @State private var month = false
    @State private var events: [CalendarEvent] = []
    @State private var incomplete = false
    @State private var loading = false
    @State private var error: String?
    @State private var calendars: [GoogleCalendarInfo] = []
    @State private var selectedCalendars: Set<String> = ["primary"]
    @State private var duration = 30
    @State private var showingSlots = false
    @State private var chosenEvent: CalendarEvent?
    private var calendar: Calendar { .current }
    private var start: Date {
        if month { return calendar.dateInterval(of: .month, for: anchor)?.start ?? calendar.startOfDay(for: anchor) }
        return calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
    }
    private var days: Int { month ? calendar.range(of: .day, in: .month, for: anchor)?.count ?? 31 : 7 }
    private var requestID: String { "\(start.timeIntervalSince1970):\(days):\(selectedCalendars.sorted()):\(store.state.account ?? "")" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous period")
                Button("Today") { anchor = Date() }
                Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next period")
                Text(anchor.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Picker("Calendar layout", selection: $month) { Text("Week").tag(false); Text("Month").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            HStack {
                Menu("Calendars") {
                    Toggle("Primary", isOn: calendarSelection("primary"))
                    ForEach(calendars.filter { $0.id != "primary" && $0.id != store.state.account }) { info in
                        Toggle(info.summary ?? info.id, isOn: calendarSelection(info.id))
                    }
                    Button("Load calendar list") {
                        Task {
                            do { calendars = try await GoogleCalendarClient(session: store.google, transport: store.transport).calendars() }
                            catch { self.error = "Could not load calendars: \(error.localizedDescription). Allow calendar-list access in Manage Google Permissions." }
                        }
                    }
                }.fixedSize()
                Button("Find a Time") { showingSlots.toggle() }
                Spacer()
            }
            if loading { ProgressView("Loading this period…").controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("\(selectedCalendars.count) selected calendar(s) · \(TimeZone.current.identifier)\(incomplete ? " · Incomplete results; verify availability in Google Calendar" : "")")
                .font(.caption).foregroundStyle(incomplete ? .orange : .secondary)
            if showingSlots { availability }
            if month { monthGrid.id("month-\(start.timeIntervalSince1970)") } else { weekGrid.id("week-\(start.timeIntervalSince1970)") }
        }.padding(20).task(id: requestID) { await load() }
            .sheet(item: $chosenEvent) { event in
                VStack(alignment: .leading, spacing: 16) {
                    Text(event.title).font(.title2.bold()); Text(CalendarAgenda.timeLabel(event)); Text(event.description).textSelection(.enabled)
                    HStack {
                        Button("Close") { chosenEvent = nil }
                        if event.etag != nil { Button("Edit & Review") { chosenEvent = nil; Task { @MainActor in await Task.yield(); store.proposeEvent(event) } } }
                        if let url = event.sourceURL { Link("Open Calendar", destination: url) }
                    }
                }.padding(24).frame(width: 540)
            }
    }
    private var weekGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 1) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 76)
                    ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).font(.caption2).foregroundStyle(.secondary).frame(height: 56, alignment: .top) }
                }.frame(width: 45)
                ForEach(0..<7) { offset in
                    let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).day())).font(.callout.bold()).frame(height: 30)
                        ScrollView { VStack(alignment: .leading) { ForEach(dayEvents(day).filter { $0.start.count == 10 }) { event in eventButton(event) } } }.frame(height: 46)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) { ForEach(0..<24) { _ in Color.clear.frame(height: 56).overlay(alignment: .top) { Divider() } } }
                            ForEach(CalendarTimeline.placements(events: events, day: day)) { placement in
                                let width = 141.0 / Double(placement.columns)
                                Button { chosenEvent = placement.event } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(placement.event.title).font(.caption.weight(.medium)).lineLimit(3)
                                        Text(CalendarAgenda.timeLabel(placement.event)).font(.system(size: 9)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(4).frame(width: width - 2, height: max(16, placement.durationMinutes * 56 / 60 - 2), alignment: .topLeading)
                                        .background(PuddleStyle.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                                }.buttonStyle(.plain).offset(x: Double(placement.column) * width + 2, y: placement.startMinute * 56 / 60)
                                    .accessibilityLabel("\(placement.event.title), \(CalendarAgenda.timeLabel(placement.event))")
                            }
                        }.frame(width: 145, height: 1344).clipped()
                    }.frame(width: 145).background(calendar.isDateInToday(day) ? PuddleStyle.teal.opacity(0.05) : Color.clear)
                }
            }
        }
    }
    private var monthGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                let padding = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
                // One identity space prevents padding/day IDs colliding in LazyVGrid.
                ForEach(-7..<(padding + days), id: \.self) { cell in
                    if cell < 0 {
                        Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + cell + 7) % 7])
                            .font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else if cell < padding { Color.clear.frame(height: 120).accessibilityHidden(true) }
                    else {
                    let offset = cell - padding
                    let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    VStack(alignment: .leading, spacing: 5) {
                        Text(day.formatted(.dateTime.day())).font(.headline)
                        ForEach(dayEvents(day).prefix(3)) { event in eventButton(event) }
                        if dayEvents(day).count > 3 { Button("+\(dayEvents(day).count - 3) more") { anchor = day; month = false } }
                        Spacer(minLength: 0)
                    }.padding(8).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .background(calendar.isDateInToday(day) ? PuddleStyle.teal.opacity(0.1) : PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
    private var availability: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Candidate times · weekday work hours").font(.callout.bold())
                Picker("Duration", selection: $duration) { Text("30 min").tag(30); Text("60 min").tag(60) }.frame(width: 130)
            }
            Text("Checks only selected calendars and loaded events. Attendee availability is not included. Refresh and review before booking.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Start hour", selection: preference(\.workdayStartHour)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("End hour", selection: preference(\.workdayEndHour)) { ForEach(1...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("Buffer", selection: preference(\.meetingBufferMinutes)) { Text("0 min").tag(0); Text("15 min").tag(15); Text("30 min").tag(30); Text("60 min").tag(60) }
            }.font(.caption)
            let slots = CalendarAvailability.slots(events: events, from: start, days: days, startHour: store.state.settings.workdayStartHour, endHour: store.state.settings.workdayEndHour, durationMinutes: duration, bufferMinutes: store.state.settings.meetingBufferMinutes)
            if slots.isEmpty { Text("No candidates in this period.").font(.caption) }
            ScrollView(.horizontal) {
                HStack { ForEach(slots) { slot in Button(slot.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())) { store.proposeTimeSlot(start: slot.start, end: slot.end) }.disabled(loading || error != nil || incomplete) } }
            }
            if let slot = slots.first { Button("Propose Focus Time in First Slot") { store.proposeTimeSlot(start: slot.start, end: slot.end); if var action = store.editingAction, case .calendar(var draft) = action.payload { draft.title = "Focus time"; action.payload = .calendar(draft); store.editingAction = action } }.disabled(loading || error != nil || incomplete) }
        }.padding(14).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func dayEvents(_ day: Date) -> [CalendarEvent] {
        CalendarAgenda(events: events, range: .today, query: "", now: day).events
    }
    private func eventButton(_ event: CalendarEvent) -> some View {
        Button { chosenEvent = event } label: {
            Text(event.title).font(.caption).lineLimit(2).padding(4).frame(maxWidth: .infinity, alignment: .leading)
                .background(PuddleStyle.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help("\(event.title) · \(CalendarAgenda.timeLabel(event))")
    }
    private func calendarSelection(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedCalendars.contains(id) }, set: { selected in
            if selected { if selectedCalendars.count < 10 { selectedCalendars.insert(id) } }
            else if selectedCalendars.count > 1 { selectedCalendars.remove(id) }
        })
    }
    private func preference(_ key: WritableKeyPath<PuddleSettings, Int>) -> Binding<Int> {
        Binding(get: { store.state.settings[keyPath: key] }, set: { value in
            do {
                var next = store.state.settings; next[keyPath: key] = value
                guard next.workdayEndHour > next.workdayStartHour else { throw PuddleError("The workday must end after it starts.") }
                try store.commit { $0.settings = next }
            } catch { store.fail(error) }
        })
    }
    private func move(_ direction: Int) { anchor = calendar.date(byAdding: month ? .month : .day, value: direction * (month ? 1 : 7), to: anchor) ?? anchor }
    private func load() async {
        loading = true; error = nil; events = []
        do {
            let page = try await store.readCalendarRange(start: start, days: days, calendarIDs: selectedCalendars.sorted())
            try Task.checkCancellation(); events = page.events; incomplete = page.hasMore; loading = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
    }
}
