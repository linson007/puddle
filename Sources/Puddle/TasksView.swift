import SwiftUI
import PuddleCore

struct TasksView: View {
    @ObservedObject var store: PuddleStore
    @State private var search = ""
    @State private var quickTitle = ""
    @State private var isAddingTask = false
    @State private var editing: AssistantTask?
    @State private var adding = false
    @FocusState private var captureFocused: Bool
    private var filter: TaskFilter { store.taskFilter }

    private func matches(at now: Date) -> [AssistantTask] {
        store.state.tasks.filter { task in
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return filter.matches(task, now: now) && (query.isEmpty || "\(task.title) \(task.owner) \(task.notes)".localizedCaseInsensitiveContains(query))
        }.sorted(by: ExecutiveBrief.taskOrder)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(at: timeline.date)
        }
        .sheet(isPresented: $adding) { CommitmentEditor(store: store) }
        .sheet(item: $editing) { CommitmentEditor(store: store, task: $0) }
    }

    private func content(at now: Date) -> some View {
        let matches = matches(at: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { heading; Spacer(minLength: 0); newTask }
                    VStack(alignment: .leading, spacing: 14) { heading; newTask }
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(PuddleStyle.teal)
                    TextField("What's the next small step?", text: $quickTitle).textFieldStyle(.plain)
                        .font(.system(size: 14)).focused($captureFocused).accessibilityLabel("Quick capture a task")
                        .onSubmit { Task { await quickAdd() } }
                    Button(L10n.text("Add task")) { Task { await quickAdd() } }.buttonStyle(PuddleSecondaryButtonStyle())
                        .disabled(isAddingTask || quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.puddleCard(padding: 12)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { filters; searchField }
                    VStack(alignment: .leading, spacing: 12) { filters; searchField }
                }
                HStack(spacing: 6) {
                    Text("\(matches.count) \(filter.rawValue.lowercased())").fontWeight(.medium)
                    Spacer()
                    Image(systemName: "star")
                    Text("Star up to three priorities for today")
                }.font(.caption).foregroundStyle(PuddleStyle.muted)
                LazyVStack(spacing: 10) {
                    ForEach(matches) { task in CommitmentRow(store: store, task: task, now: now) { editing = task } }
                }
                if matches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(PuddleStyle.teal)
                        Text(L10n.text(search.isEmpty ? filter.emptyTitle : "No matching tasks")).font(.headline)
                        Text(L10n.text(search.isEmpty ? filter.emptyMessage : "Try another title, owner or note."))
                            .font(.callout).foregroundStyle(PuddleStyle.muted).multilineTextAlignment(.center)
                        if !search.isEmpty {
                            Button("Clear search") { search = "" }.buttonStyle(PuddleSecondaryButtonStyle())
                        } else if filter == .open {
                            Button("Capture a task") { captureFocused = true }.buttonStyle(PuddleSecondaryButtonStyle())
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 36).puddleCard()
                }
                Text("Tasks and owners stay on this Mac. \(store.state.settings.notifications ? "" : "Enable notifications in Settings → Assistant for reminders while Puddle is closed.")")
                    .font(.caption).foregroundStyle(PuddleStyle.muted)
            }.frame(maxWidth: 940, alignment: .leading).padding(30).frame(maxWidth: .infinity)
        }
    }

    private var filters: some View {
        Picker("Show commitments", selection: $store.taskFilter) {
            ForEach(TaskFilter.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(minWidth: 390, maxWidth: 440)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A little more follow-through.").font(.system(size: 29, weight: .semibold, design: .rounded))
                .tracking(-0.6).foregroundStyle(PuddleStyle.ink).accessibilityAddTraits(.isHeader)
            Text("Your next actions, reminders and the people you're waiting on.")
                .font(.callout).foregroundStyle(PuddleStyle.muted)
        }
    }

    private var newTask: some View {
        Button { adding = true } label: { Label(L10n.text("New task"), systemImage: "plus") }.buttonStyle(PuddlePrimaryButtonStyle())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(PuddleStyle.muted)
            TextField("Search title, owner or notes", text: $search).textFieldStyle(.plain).accessibilityLabel(L10n.text("Search tasks"))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(PuddleStyle.muted).accessibilityLabel("Clear task search")
            }
        }.padding(9).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PuddleStyle.line))
            .frame(minWidth: 200)
    }

    private func quickAdd() async {
        guard !isAddingTask else { return }
        let title = quickTitle
        isAddingTask = true; defer { isAddingTask = false }
        if await store.addTask(title: title, dueAt: nil) {
            if quickTitle == title { quickTitle = "" }
            search = ""; store.taskFilter = .open
        }
    }
}

struct CommitmentRow: View {
    @ObservedObject var store: PuddleStore
    let task: AssistantTask
    var now = Date()
    var onEdit: () -> Void
    @State private var deleting = false
    private var focused: Bool { task.focusDate.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { Task { await store.toggleTask(task.id) } } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(task.completed ? PuddleStyle.teal : .secondary)
            }.buttonStyle(.plain).frame(width: 24, height: 24)
                .accessibilityLabel(task.completed ? "Reopen \(task.title)" : "Complete \(task.title)")
                .accessibilityValue(L10n.text(task.completed ? "Completed" : "Open"))
                .accessibilityHint("Changes completion status and saves the task")
            VStack(alignment: .leading, spacing: 7) {
                Button(action: onEdit) {
                    Text(task.title).font(.system(size: 13, weight: .medium)).strikethrough(task.completed)
                        .foregroundStyle(task.completed ? PuddleStyle.muted : PuddleStyle.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).accessibilityLabel("Edit \(task.title)").help("Edit task")
                HStack(spacing: 10) {
                    if task.priority != .normal { Label(task.priority.label, systemImage: "flag").foregroundStyle(task.priority == .high ? .orange : .secondary) }
                    if !task.owner.isEmpty {
                        Label(task.workflow == .waiting ? "Waiting on \(task.owner)" : "Owner: \(task.owner)", systemImage: task.workflow == .waiting ? "hourglass" : "person")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if let due = task.dueAt {
                    Text("\(task.workflow == .waiting ? "Follow up" : "Due") \(due.formatted(date: .abbreviated, time: .shortened))\(!task.completed && due < now ? " · overdue" : "")")
                        .font(.caption).foregroundStyle(!task.completed && due < now ? .orange : .secondary)
                }
                if !task.notes.isEmpty { DisclosureGroup("Notes") { Text(task.notes).font(.callout).textSelection(.enabled) } }
                if let source = task.meetingSource {
                    if let note = store.state.meetings.first(where: { $0.id == source.meetingID }) {
                        Button("From meeting: \(note.title)") { store.meetingWorkspace.selectedID = note.id; store.section = .meetings }
                            .buttonStyle(PuddleTextButtonStyle()).font(.caption)
                    }
                    DisclosureGroup("Source quote") { Text(source.quote).font(.caption).textSelection(.enabled) }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !task.completed {
                Button { Task { await store.setDailyPriority(task.id, enabled: !focused, now: now) } } label: {
                    Image(systemName: focused ? "star.fill" : "star").foregroundStyle(focused ? PuddleStyle.teal : .secondary)
                }.buttonStyle(.plain).frame(width: 24, height: 24).help(focused ? "Remove from today's priorities" : "Make a priority for today")
                    .accessibilityLabel(focused ? "Remove \(task.title) from today's priorities" : "Prioritize \(task.title) today")
                    .accessibilityValue(focused ? "Priority selected" : "Not a priority")
            }
            Menu {
                Button(L10n.text("Edit…"), action: onEdit)
                if !task.completed {
                    Button("Snooze 10 minutes") { Task { await store.snoozeTask(task.id) } }
                    Button("Snooze 24 hours") { Task { await store.snoozeTask(task.id, minutes: 1440) } }
                }
                Divider()
                Button(L10n.text("Delete…"), role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                .accessibilityLabel("Actions for \(task.title)")
        }.puddleCard(padding: 14)
            .confirmationDialog("Delete this commitment?", isPresented: $deleting, titleVisibility: .visible) {
                Button(L10n.text("Delete"), role: .destructive) { Task { await store.deleteTask(task.id) } }
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: { Text(task.title) }
    }
}

struct CommitmentEditor: View {
    @ObservedObject var store: PuddleStore
    let task: AssistantTask?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskDraft
    @State private var dated: Bool
    @State private var due: Date
    init(store: PuddleStore, task: AssistantTask? = nil, initialDraft: TaskDraft? = nil) {
        self.store = store; self.task = task
        let draft = initialDraft ?? TaskDraft(task ?? AssistantTask(title: ""))
        _draft = State(initialValue: draft)
        _dated = State(initialValue: draft.dueAt != nil)
        _due = State(initialValue: draft.dueAt ?? Date().addingTimeInterval(3600))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(task == nil ? "New commitment" : "Edit commitment").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Next action", text: $draft.title).textFieldStyle(.roundedBorder)
                Picker("Status", selection: $draft.workflow) {
                    ForEach(TaskWorkflow.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField(draft.workflow == .waiting ? "Waiting on" : "Owner (optional)", text: $draft.owner).textFieldStyle(.roundedBorder)
                Picker("Project", selection: $draft.projectID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(store.state.workProjects) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker(L10n.text("Priority"), selection: $draft.priority) {
                    ForEach(TaskPriority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(draft.workflow == .waiting ? "Set a follow-up reminder" : "Set a due date & reminder", isOn: $dated)
                if dated { DatePicker(draft.workflow == .waiting ? "Follow up at" : "Due at", selection: $due) }
                Picker("Repeat after completion", selection: $draft.frequency) {
                    Text("Does not repeat").tag(Optional<TaskFrequency>.none)
                    ForEach(TaskFrequency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }.disabled(!dated)
                TextField(L10n.text("Notes"), text: $draft.notes, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
            }
            Text("Saved on this Mac. Assigning an owner does not send them a message.").font(.caption).foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Commitment") { Task {
                    draft.dueAt = dated ? due : nil
                    if !dated { draft.frequency = nil }
                    if await store.saveCommitment(draft, taskID: task?.id) { dismiss() }
                } }.buttonStyle(PuddlePrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 540).background(PuddleStyle.background)
    }
}
