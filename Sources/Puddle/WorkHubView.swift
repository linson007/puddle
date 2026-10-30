import SwiftUI
import PuddleCore

struct WorkHubView: View {
    @ObservedObject var store: PuddleStore
    @State private var tab = 0
    @State private var deleting: (kind: String, id: UUID, title: String)?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Projects, people & decisions").font(.largeTitle.bold())
            Picker("Workspace", selection: $tab) { Text("Projects").tag(0); Text("People").tag(1); Text("Decisions").tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 {
                        Button("New Project") { store.editingWorkProject = WorkProject() }
                        ForEach(store.state.workProjects) { project in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(project.title).font(.headline); Spacer(); Text(project.status.rawValue.capitalized).font(.caption); Button("Edit") { store.editingWorkProject = project }; Button("Delete…", role: .destructive) { deleting = ("project", project.id, project.title) } }
                                Text(project.objective).font(.callout).textSelection(.enabled)
                                if !project.successCriteria.isEmpty { Text("Success: \(project.successCriteria)").font(.caption).foregroundStyle(.secondary) }
                                Text("\(store.state.tasks.filter { $0.projectID == project.id && !$0.completed }.count) open commitments · \(store.state.meetings.filter { $0.projectID == project.id }.count) meetings · \(store.state.workDecisions.filter { $0.projectID == project.id }.count) decisions").font(.caption)
                                ForEach(store.state.tasks.filter { $0.projectID == project.id && !$0.completed }) { task in Button(task.title) { store.editingCommitment = task } }
                            }.workCard()
                        }
                    } else if tab == 1 {
                        Button("New Person") { store.editingPerson = PersonContext() }
                        Text("User-maintained relationship context. VIPs affect explainable mail attention; assigning work never contacts anyone.").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.state.people) { person in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Label(person.name, systemImage: person.isVIP ? "star.fill" : "person").font(.headline); Spacer(); Button("Edit") { store.editingPerson = person }; Button("Forget…", role: .destructive) { deleting = ("person", person.id, person.name) } }
                                Text([person.role, person.email].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if let date = person.lastInteraction { Text("Last interaction: \(date.formatted())").font(.caption) }
                                if !person.promises.isEmpty { Text("Promises: \(person.promises)").font(.callout) }
                                if !person.talkingPoints.isEmpty { Text("Talking points: \(person.talkingPoints)").font(.callout) }
                                if let url = person.sourceURL { Link("Source", destination: url) }
                            }.workCard()
                        }
                    } else {
                        Button("New Decision") { store.editingDecision = WorkDecision() }
                        ForEach(store.state.workDecisions) { decision in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(decision.title).font(.headline); Spacer(); Text(decision.status.rawValue.capitalized).font(.caption); Button("Edit") { store.editingDecision = decision }; Button("Delete…", role: .destructive) { deleting = ("decision", decision.id, decision.title) } }
                                Text(decision.rationale).font(.callout).textSelection(.enabled)
                                if let date = decision.reviewAt { Label("Review: \(date.formatted())", systemImage: date < Date() ? "exclamationmark.circle" : "calendar").font(.caption).foregroundStyle(date < Date() ? .orange : .secondary) }
                                if !decision.outcome.isEmpty { Text("Outcome: \(decision.outcome)").font(.callout) }
                                ForEach(Array(decision.evidence.enumerated()), id: \.offset) { _, item in Link(item.title, destination: item.url) }
                            }.workCard()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(28).confirmationDialog("Delete \(deleting?.title ?? "this record")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Record", role: .destructive) { if let value = deleting { store.deleteWorkRecord(kind: value.kind, id: value.id) }; deleting = nil }
            Button("Cancel", role: .cancel) {}
        }
    }
}
private extension View { func workCard() -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 10)) } }

struct WorkProjectEditor: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var project: WorkProject
    init(store: PuddleStore, project: WorkProject) { self.store = store; _project = State(initialValue: project) }
    var body: some View {
        WorkRecordForm(store: store, title: "Project & goal", save: { store.saveWorkProject(project) }, close: { dismiss() }) {
            TextField("Project name", text: $project.title)
            TextField("Objective", text: $project.objective, axis: .vertical).lineLimit(3...6)
            TextField("Success criteria", text: $project.successCriteria, axis: .vertical).lineLimit(3...6)
            Picker("Status", selection: $project.status) { ForEach(ProjectProgress.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
        }
    }
}
struct PersonContextEditor: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var person: PersonContext
    init(store: PuddleStore, person: PersonContext) { self.store = store; _person = State(initialValue: person) }
    var body: some View {
        WorkRecordForm(store: store, title: "Person & relationship context", save: { store.savePerson(person) }, close: { dismiss() }) {
            TextField("Name", text: $person.name); TextField("Email", text: $person.email); TextField("Role", text: $person.role)
            Toggle("VIP sender", isOn: $person.isVIP)
            Toggle("Record last interaction", isOn: Binding(get: { person.lastInteraction != nil }, set: { person.lastInteraction = $0 ? Date() : nil }))
            if person.lastInteraction != nil { DatePicker("Last interaction", selection: Binding(get: { person.lastInteraction ?? Date() }, set: { person.lastInteraction = $0 })) }
            TextField("Promises and commitments", text: $person.promises, axis: .vertical).lineLimit(2...4)
            TextField("Talking points", text: $person.talkingPoints, axis: .vertical).lineLimit(2...4)
            TextField("Notes", text: $person.notes, axis: .vertical).lineLimit(2...4)
            if let url = person.sourceURL { Link("Original source", destination: url) }
        }
    }
}
struct WorkDecisionEditor: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var decision: WorkDecision
    @State private var links: String
    init(store: PuddleStore, decision: WorkDecision) { self.store = store; _decision = State(initialValue: decision); _links = State(initialValue: decision.evidence.map { $0.url.absoluteString }.joined(separator: "\n")) }
    var body: some View {
        WorkRecordForm(store: store, title: "Decision record", save: {
            var next = decision
            let urls = links.split(whereSeparator: \.isNewline).compactMap { URL(string: String($0)) }
            guard urls.count == links.split(whereSeparator: \.isNewline).count else { store.fail(PuddleError("Check each evidence URL.")); return false }
            next.evidence = urls.map { SourceReference(title: $0.host ?? $0.lastPathComponent, url: $0) }; return store.saveDecision(next)
        }, close: { dismiss() }) {
            TextField("Decision", text: $decision.title); projectPicker($decision.projectID)
            TextField("Owner", text: $decision.owner)
            TextField("Options considered", text: $decision.options, axis: .vertical).lineLimit(2...4)
            TextField("Rationale", text: $decision.rationale, axis: .vertical).lineLimit(2...4)
            TextField("Evidence URLs, one per line", text: $links, axis: .vertical).lineLimit(2...4)
            Picker("Status", selection: $decision.status) { ForEach(DecisionProgress.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Toggle("Set review date", isOn: Binding(get: { decision.reviewAt != nil }, set: { decision.reviewAt = $0 ? Date().addingTimeInterval(7 * 86400) : nil }))
            if decision.reviewAt != nil { DatePicker("Review", selection: Binding(get: { decision.reviewAt ?? Date() }, set: { decision.reviewAt = $0 })) }
            TextField("Outcome", text: $decision.outcome, axis: .vertical).lineLimit(2...4)
        }
    }
    private func projectPicker(_ selection: Binding<UUID?>) -> some View { Picker("Project", selection: selection) { Text("None").tag(Optional<UUID>.none); ForEach(store.state.workProjects) { Text($0.title).tag(Optional($0.id)) } } }
}
private struct WorkRecordForm<Content: View>: View {
    @ObservedObject var store: PuddleStore
    let title: String; let save: () -> Bool; let close: () -> Void; @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold()); Form { content() }.textFieldStyle(.roundedBorder)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel", action: close); Spacer(); Button("Save") { if save() { close() } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 640)
    }
}

extension PuddleStore {
    func deleteWorkRecord(kind: String, id: UUID) {
        do { try commit { next in
            if kind == "person" { next.people.removeAll { $0.id == id } }
            if kind == "decision" { next.workDecisions.removeAll { $0.id == id } }
            if kind == "project" {
                next.workProjects.removeAll { $0.id == id }
                for index in next.tasks.indices where next.tasks[index].projectID == id { next.tasks[index].projectID = nil }
                for index in next.meetings.indices where next.meetings[index].projectID == id { next.meetings[index].projectID = nil }
                for index in next.workDecisions.indices where next.workDecisions[index].projectID == id { next.workDecisions[index].projectID = nil }
            }
        } } catch { fail(error) }
    }
    func workContext(_ query: String) -> String {
        func match(_ id: UUID, _ text: String) -> Bool { query.isEmpty || id.uuidString == query || text.localizedCaseInsensitiveContains(query) }
        let projects = state.workProjects.filter { match($0.id, $0.title + " " + $0.objective) }.prefix(10).map { ["id": $0.id.uuidString, "title": $0.title, "objective": String($0.objective.prefix(1000)), "success": String($0.successCriteria.prefix(500)), "status": $0.status.rawValue] }
        let people = state.people.filter { match($0.id, $0.name + " " + $0.email + " " + $0.notes) }.prefix(10).map { ["id": $0.id.uuidString, "name": $0.name, "email": $0.email, "role": $0.role, "promises": String($0.promises.prefix(1000)), "talking_points": String($0.talkingPoints.prefix(1000)), "notes": String($0.notes.prefix(1000)), "last_interaction": $0.lastInteraction?.ISO8601Format() ?? "", "source": $0.sourceURL?.absoluteString ?? ""] }
        let decisions: [[String: Any]] = state.workDecisions.filter { match($0.id, $0.title + " " + $0.rationale) }.prefix(10).map { ["id": $0.id.uuidString, "title": $0.title, "owner": $0.owner, "project_id": $0.projectID?.uuidString ?? "", "options": String($0.options.prefix(1000)), "rationale": String($0.rationale.prefix(1000)), "outcome": String($0.outcome.prefix(1000)), "review_at": $0.reviewAt?.ISO8601Format() ?? "", "status": $0.status.rawValue, "evidence": $0.evidence.prefix(5).map { ["title": $0.title, "url": $0.url.absoluteString] }] }
        let object: [String: Any] = ["scope": "Bounded user-maintained records, not inferred facts or proof of execution.", "projects": projects, "people": people, "decisions": decisions]
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    @discardableResult func saveWorkProject(_ value: WorkProject) -> Bool {
        do { let next = try value.validated(); try commit { snapshot in
            if let index = snapshot.workProjects.firstIndex(where: { $0.id == next.id }) { snapshot.workProjects[index] = next } else { snapshot.workProjects.append(next) }
        }; errorMessage = nil; return true } catch { fail(error); return false }
    }
    @discardableResult func savePerson(_ value: PersonContext) -> Bool {
        do { let next = try value.validated(); try commit { snapshot in
            if let index = snapshot.people.firstIndex(where: { $0.id == next.id }) { snapshot.people[index] = next } else { snapshot.people.append(next) }
        }; errorMessage = nil; return true } catch { fail(error); return false }
    }
    @discardableResult func saveDecision(_ value: WorkDecision) -> Bool {
        do { var next = try value.validated()
            if let id = next.projectID, !state.workProjects.contains(where: { $0.id == id }) { next.projectID = nil }
            try commit { snapshot in
            if let index = snapshot.workDecisions.firstIndex(where: { $0.id == next.id }) { snapshot.workDecisions[index] = next } else { snapshot.workDecisions.append(next) }
        }; errorMessage = nil; return true } catch { fail(error); return false }
    }
    func addSenderContext(_ message: MailMessage) {
        let email = MailDraft.mailbox(message.sender)
        var person = state.people.first { $0.email.caseInsensitiveCompare(email) == .orderedSame } ?? PersonContext()
        if person.name.isEmpty { person.name = message.sender; person.email = email; person.sourceURL = message.sourceURL }
        editingPerson = person
    }
}
