import SwiftUI
import PuddleCore

struct TodayView: View {
    @ObservedObject var store: PuddleStore
    @State private var showingProfile = false
    @State private var adding = false
    @State private var editing: AssistantTask?
    @State private var preparing: CalendarEvent?
    @State private var expandedAgenda = false
    @AppStorage("todaySetupDismissed") private var setupDismissed = false

    private var canAsk: Bool { !store.isThinking && (store.demo || store.splashModel != nil) }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let brief = ExecutiveBrief(snapshot: store.state, now: timeline.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(brief)
                        if (!setupDismissed && !store.state.profile.configured) || (!store.demo && store.splashModel == nil) { setup }
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 18) {
                                priorities(brief).frame(maxWidth: .infinity)
                                agenda(brief).frame(maxWidth: .infinity)
                            }
                        } else {
                            priorities(brief)
                            agenda(brief)
                        }
                        HStack(spacing: 12) {
                            metric("Overdue", value: brief.overdue.count, icon: "exclamationmark.circle", attention: !brief.overdue.isEmpty, destination: .tasks)
                            metric("Waiting on", value: brief.waiting.count, icon: "hourglass", attention: false, destination: .tasks)
                            metric("On the agenda", value: brief.agenda.count, icon: "calendar", attention: false, destination: .calendar)
                        }
                        assistantBrief
                        if !brief.overdue.isEmpty { commitments("Needs a follow-up", tasks: brief.overdue, now: timeline.date) }
                        if !brief.dueToday.isEmpty { commitments("Due later today", tasks: brief.dueToday, now: timeline.date) }
                        let dueIDs = Set((brief.overdue + brief.dueToday).map(\.id))
                        let waiting = brief.waiting.filter { !dueIDs.contains($0.id) }
                        if !waiting.isEmpty { commitments("Waiting on others", tasks: waiting, now: timeline.date) }
                        flaggedMail(brief)
                        HStack(alignment: .top) {
                            Label("Saved work & cached connections · \(TimeZone.current.identifier)", systemImage: "internaldrive")
                                .font(.caption).foregroundStyle(PuddleStyle.muted)
                            Spacer()
                            Button("Profiles") { showingProfile = true }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
                        }
                    }.frame(maxWidth: 1080, alignment: .leading)
                        .padding(geometry.size.width < 600 ? 20 : 30).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showingProfile) { AssistantProfilesView(store: store) }
        .sheet(isPresented: $adding) { CommitmentEditor(store: store) }
        .sheet(item: $editing) { CommitmentEditor(store: store, task: $0) }
        .sheet(item: $preparing) { MeetingPreparationView(store: store, event: $0) }
    }

    private func header(_ brief: ExecutiveBrief) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(brief.date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(PuddleStyle.muted)
                    Text(store.state.profile.name.isEmpty ? "Your day, in focus." : "Your day, \(store.state.profile.name).")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.7)
                        .foregroundStyle(PuddleStyle.ink).accessibilityAddTraits(.isHeader)
                    Text("A few things that matter. A little room to breathe.")
                        .font(.callout).foregroundStyle(PuddleStyle.muted)
                    if !store.state.profile.role.isEmpty || !store.state.profile.organization.isEmpty {
                        Text([store.state.profile.role, store.state.profile.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(PuddleStyle.muted)
                    }
                }
                Spacer(minLength: 0)
                Button { adding = true } label: { Label("New task", systemImage: "plus") }
                    .buttonStyle(PuddleSecondaryButtonStyle()).help("Capture a commitment · ⌘⇧N")
            }
            if !store.state.profile.objectives.isEmpty {
                DisclosureGroup(store.state.profileLibrary.active.kind.objectivesLabel) {
                    Text(store.state.profile.objectives).font(.callout).textSelection(.enabled).padding(.top, 5)
                }.font(.callout).foregroundStyle(PuddleStyle.muted)
            }
        }.padding(.bottom, 4)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(PuddleStyle.teal).padding(9)
                    .background(PuddleStyle.inset, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.splashModel == nil && !store.demo ? "Meet your local assistant" : "Make Puddle yours").font(.headline)
                    Text("Add your context and connect the tools you use, at your own pace.")
                        .font(.caption).foregroundStyle(PuddleStyle.muted)
                }
                Spacer(minLength: 0)
                if store.splashModel != nil || store.demo {
                    Button { setupDismissed = true } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(PuddleStyle.muted).accessibilityLabel("Dismiss optional setup")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { setupActions }
                VStack(alignment: .leading, spacing: 10) { setupActions }
            }
            if !store.storageAvailable && !store.demo {
                Label("Local storage needs attention before changes can be saved.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry loading saved data") { Task { await store.retryLoadingState() } }
            }
        }.puddleCard(padding: 16)
    }

    @ViewBuilder private var setupActions: some View {
        Button(store.state.profile.configured ? "Manage profiles" : "Choose a profile") { showingProfile = true }
            .buttonStyle(PuddleSecondaryButtonStyle())
        if store.splashModel == nil && !store.demo {
            Button { store.showLocalSetup = true } label: { Label("Set up local AI", systemImage: "desktopcomputer") }
                .buttonStyle(PuddlePrimaryButtonStyle())
        } else {
            Label(store.demo ? "Demo workspace" : "Local AI connected", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(PuddleStyle.teal)
        }
        Button("Optional connections") { store.section = .connections }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
    }

    private func metric(_ title: String, value: Int, icon: String, attention: Bool, destination: PuddleStore.Section) -> some View {
        Button { store.section = destination } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(attention ? Color.orange : PuddleStyle.teal)
                Text(String(value)).font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(attention ? Color.orange : PuddleStyle.ink).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(PuddleStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).puddleCard(padding: 14)
        }.buttonStyle(.plain).help("Open \(destination.rawValue)")
    }

    private var assistantBrief: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { briefIntroduction; Spacer(minLength: 0); briefActions }
            VStack(alignment: .leading, spacing: 14) { briefIntroduction; briefActions }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PuddleStyle.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PuddleStyle.line))
    }

    private var briefIntroduction: some View {
        HStack(spacing: 10) {
            PuddleMark(size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready when you are.").font(.system(size: 13, weight: .medium))
                Text("Turn your saved work into a plan for the day.").font(.caption).foregroundStyle(PuddleStyle.muted)
            }
        }
    }

    private var briefActions: some View {
        HStack(spacing: 12) {
            Button("End-of-day review") {
                store.ask("Read my daily brief and help me close out the day. Review open priorities and commitments and suggest what to carry forward or follow up. Ask me what was completed; do not assume progress or change anything.")
            }.buttonStyle(PuddleTextButtonStyle()).font(.caption).disabled(!canAsk)
            Button(store.state.profileLibrary.active.kind.planLabel) { store.ask(store.state.profileLibrary.active.kind.planQuestion) }
                .buttonStyle(PuddlePrimaryButtonStyle()).disabled(!canAsk)
        }
    }

    private func priorities(_ brief: ExecutiveBrief) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Your priorities", systemImage: "sun.max").font(.headline).foregroundStyle(PuddleStyle.ink)
                Spacer()
                Text("\(brief.priorities.count) / 3").font(.caption.weight(.medium)).foregroundStyle(PuddleStyle.teal)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(PuddleStyle.inset, in: Capsule())
            }
            Text("Three things. One clear starting point.").font(.caption).foregroundStyle(PuddleStyle.muted)
            ForEach(brief.priorities) { task in
                CommitmentRow(store: store, task: task, now: brief.date) { editing = task }
            }
            if brief.priorities.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What would make today feel successful?").font(.system(size: 15, weight: .medium))
                    Text("Star up to three tasks to keep them here. Your focus resets each day; your tasks stay saved.")
                        .font(.callout).foregroundStyle(PuddleStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Choose from tasks") { store.section = .tasks }.buttonStyle(PuddleSecondaryButtonStyle())
                }.padding(.vertical, 18)
            } else {
                Button("Choose from tasks") { store.section = .tasks }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }
        }.frame(minHeight: 235, alignment: .topLeading).puddleCard()
    }

    private func commitments(_ title: String, tasks: [AssistantTask], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("All commitments (\(tasks.count))") { store.section = .tasks }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }
            ForEach(tasks.prefix(4)) { task in CommitmentRow(store: store, task: task, now: now) { editing = task } }
        }
    }

    private func agenda(_ brief: ExecutiveBrief) -> some View {
        let upcoming = brief.agenda.filter { $0.allDay || ($0.end ?? $0.start) > brief.date }
        let visible = expandedAgenda ? brief.agenda : Array(upcoming.prefix(3))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Today's agenda", systemImage: "calendar").font(.headline).foregroundStyle(PuddleStyle.ink)
                Spacer()
                Button { store.refresh() } label: {
                    if store.isRefreshingCalendar { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).frame(width: 24, height: 24)
                    .disabled(store.demo || store.isSyncing || store.isRefreshingCalendar || (!store.mailConnected && !store.calendarConnected))
                    .accessibilityLabel("Refresh connections").help("Refresh mail and calendar")
            }
            Text(freshness(store.state.calendarLastSync)).font(.caption).foregroundStyle(PuddleStyle.muted)
            if !store.calendarConnected {
                Text("Bring a little context to your day.").font(.system(size: 15, weight: .medium)).padding(.top, 16)
                Text("Connect Google Calendar to see your schedule, prepare for meetings and spot overlaps.")
                    .font(.callout).foregroundStyle(PuddleStyle.muted)
                Button("Connect calendar") { store.section = .calendar }.buttonStyle(PuddleSecondaryButtonStyle())
            } else if brief.agenda.isEmpty {
                Label("A little breathing room.", systemImage: "leaf").font(.callout).padding(.top, 16)
                Text(store.state.calendarLastSync == nil ? "Refresh your calendar to load today's agenda." : "No events in today's cached agenda.")
                    .font(.callout).foregroundStyle(PuddleStyle.muted)
            } else if visible.isEmpty {
                Text("Your scheduled day is wrapped up.").font(.callout).padding(.vertical, 12)
            }
            ForEach(visible) { item in
                agendaRow(item, brief: brief)
                if item.id != visible.last?.id { Divider().overlay(PuddleStyle.line) }
            }
            if brief.agenda.count > visible.count || expandedAgenda {
                Button(expandedAgenda ? "Show upcoming" : "Show full day (\(brief.agenda.count))") { expandedAgenda.toggle() }
                    .buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }
            HStack {
                Text("\(brief.agenda.count) events today").font(.caption).foregroundStyle(PuddleStyle.muted)
                Spacer()
                Button("Open Calendar") { store.section = .calendar }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }.padding(.top, 4)
            if store.state.calendarHasMore {
                Label("Calendar results are incomplete. Open Calendar for all events.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.calendarConnected {
                Text("Primary calendar · Overlaps use known start and end times.")
                    .font(.caption2).foregroundStyle(PuddleStyle.muted)
            }
        }.frame(minHeight: 235, alignment: .topLeading).puddleCard()
    }

    private func agendaRow(_ item: AgendaItem, brief: ExecutiveBrief) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(item.isOngoing(at: brief.date) ? PuddleStyle.teal : PuddleStyle.teal.opacity(0.3))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.allDay ? "All day" : CalendarAgenda.timeLabel(item.event)).font(.caption).foregroundStyle(PuddleStyle.muted)
                Text(item.event.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !item.event.location.isEmpty { Text(item.event.location).font(.caption).foregroundStyle(PuddleStyle.muted).lineLimit(2) }
                if item.isOngoing(at: brief.date) { Text("In progress").font(.caption.weight(.medium)).foregroundStyle(PuddleStyle.teal) }
                if !item.conflicts.isEmpty {
                    Label("Overlaps: " + brief.agenda.filter { item.conflicts.contains($0.id) }.map { $0.event.title }.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 14) {
                    Button("Prepare") { preparing = item.event }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
                        .accessibilityLabel("Prepare for \(item.event.title)")
                    if let link = item.event.joinLinks.first {
                        Button("Join") { store.openMeetingLink(link.url.absoluteString) }.buttonStyle(PuddleTextButtonStyle()).font(.caption).disabled(store.demo)
                            .accessibilityLabel("Join \(item.event.title)")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }

    private func flaggedMail(_ brief: ExecutiveBrief) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mail that needs you", systemImage: "envelope.badge").font(.headline)
                Text("\(brief.flaggedMail.count)").font(.caption).foregroundStyle(PuddleStyle.muted)
                Spacer()
                Button("Open Mail") { store.section = .mail }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }
            Text(freshness(store.mailLastSync)).font(.caption).foregroundStyle(PuddleStyle.muted)
            if !store.mailConnected {
                Text("Connect mail to bring important unread messages into your day.").font(.callout).foregroundStyle(PuddleStyle.muted)
                Button("Connect mail") { store.section = .mail }.buttonStyle(PuddleSecondaryButtonStyle())
            } else if brief.flaggedMail.isEmpty {
                Text("No unread VIP or Important messages in the cached inbox.").font(.callout).foregroundStyle(PuddleStyle.muted)
            }
            ForEach(brief.flaggedMail.prefix(5)) { message in
                HStack(spacing: 12) {
                    Image(systemName: "envelope").foregroundStyle(PuddleStyle.teal).padding(10)
                        .background(PuddleStyle.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.subject).font(.callout.weight(.medium)).lineLimit(2)
                        Text(message.sender).font(.caption).foregroundStyle(PuddleStyle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Link(destination: message.sourceURL) { Image(systemName: "arrow.up.right") }
                        .accessibilityLabel("Open source: \(message.subject)")
                }
                if message.id != brief.flaggedMail.prefix(5).last?.id { Divider().overlay(PuddleStyle.line) }
            }
            if brief.flaggedMail.count > 5 { Text("Showing 5 of \(brief.flaggedMail.count) flagged messages in the cache.").font(.caption).foregroundStyle(PuddleStyle.muted) }
            Text("Unread VIP and Important messages · Selected provider's 50 most recent inbox messages · Partial view")
                .font(.caption2).foregroundStyle(PuddleStyle.muted)
        }.puddleCard()
    }

    private func freshness(_ date: Date?) -> String {
        guard let date else { return "Not refreshed" }
        return "\(Date().timeIntervalSince(date) > 900 ? "Cached · " : "")Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
