import SwiftUI
import PuddleCore

struct RoutinesView: View {
    @ObservedObject var store: PuddleStore
    @State private var editing: AssistantRoutine?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Routines").font(.largeTitle.bold()); Spacer(); Button("New Routine") { editing = AssistantRoutine() } }
                Text("Local briefings and reviews run while Puddle is running, including with its main window closed. After quitting or sleep, recent missed runs can catch up once; older runs are recorded as missed. Routines can read context, but cannot send, book, or change provider data.").font(.callout).foregroundStyle(.secondary)
                if store.state.routines.isEmpty {
                    ContentUnavailableView("Make useful work repeatable", systemImage: "repeat", description: Text("Schedule a morning brief, end-of-day review, or waiting-on follow-up review."))
                }
                ForEach(store.state.routines) { routine in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(routine.title).font(.headline); Spacer()
                            Toggle("Enabled", isOn: Binding(get: { routine.enabled }, set: { enabled in var next = routine; next.enabled = enabled; _ = store.saveRoutine(next) })).labelsHidden()
                        }
                        Text(String(format: "%02d:%02d", routine.hour, routine.minute) + " · " + routine.timezone).font(.caption).foregroundStyle(.secondary)
                        if routine.enabled, let date = routine.nextRunAt { Text("Next: \(date.formatted())").font(.caption) }
                        HStack {
                            Button("Edit") { editing = routine }
                            Button("Run Now") { store.runRoutineNow(routine.id) }.disabled(store.routineTask != nil || store.privateSession)
                            Button("Pause Current Run") { store.pauseRoutineWork() }.disabled(store.routineTask == nil)
                        }
                        ForEach(store.state.routineRuns.filter { $0.routineID == routine.id }.prefix(5)) { run in
                            DisclosureGroup("\(run.status.rawValue.capitalized) · \(run.scheduledAt.formatted())") {
                                Text(run.result).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption)
                        }
                    }.padding(18).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.sheet(item: $editing) { routine in RoutineEditor(store: store, initial: routine) }
    }
}
private struct RoutineEditor: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var routine: AssistantRoutine
    init(store: PuddleStore, initial: AssistantRoutine) { self.store = store; _routine = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scheduled local routine").font(.title2.bold())
            TextField("Name", text: $routine.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $routine.prompt).frame(height: 130).accessibilityLabel("Routine prompt")
            HStack {
                Picker("Hour", selection: $routine.hour) { ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) } }
                Picker("Minute", selection: $routine.minute) { ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) } }
            }
            TextField("Timezone", text: $routine.timezone).textFieldStyle(.roundedBorder)
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: { routine.weekdays.contains(day) }, set: { selected in
                        if selected { routine.weekdays.append(day) } else { routine.weekdays.removeAll { $0 == day } }
                    })).toggleStyle(.checkbox)
                }
            }
            Toggle("Enable this schedule", isOn: $routine.enabled)
            Text("Runs use your local model and inspectable read tools. No external write tools or automatic memory learning are available.").font(.caption).foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save Routine") { if store.saveRoutine(routine) { dismiss() } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 650)
    }
}

extension PuddleStore {
    @discardableResult func saveRoutine(_ original: AssistantRoutine) -> Bool {
        guard !privateSession, !isLocked else { return false }
        do {
            var routine = try original.validated(); routine.nextRunAt = routine.enabled ? routine.nextFire(after: Date()) : nil
            guard state.routines.count < 50 || state.routines.contains(where: { $0.id == routine.id }) else { throw PuddleError("Keep up to 50 routines.") }
            try commit { next in
                if let index = next.routines.firstIndex(where: { $0.id == routine.id }) { next.routines[index] = routine }
                else { next.routines.append(routine) }
            }; errorMessage = nil; return true
        } catch { fail(error); return false }
    }
    func processRoutines(now: Date = Date()) {
        guard routineTask == nil, !demo, !privateSession, !isLocked, storageAvailable else { return }
        guard let routine = state.routines.filter({ $0.enabled && ($0.nextRunAt ?? .distantFuture) <= now }).sorted(by: { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }).first else { return }
        let scheduled = routine.nextRunAt ?? now
        if now.timeIntervalSince(scheduled) > 6 * 3600 {
            var run = RoutineRun(routineID: routine.id, scheduledAt: scheduled, status: .missed); run.result = "Missed while Puddle was unavailable. No model or provider request was made."
            do { try commit { next in
                next.routineRuns.insert(run, at: 0); next.routineRuns = Array(next.routineRuns.prefix(500))
                if let index = next.routines.firstIndex(where: { $0.id == routine.id }) { next.routines[index].nextRunAt = routine.nextFire(after: now) }
            } } catch { fail(error) }
        } else { launchRoutine(routine, scheduled: scheduled, now: now) }
    }
    func runRoutineNow(_ id: UUID, now: Date = Date()) {
        guard routineTask == nil, !demo, !privateSession, !isLocked, let routine = state.routines.first(where: { $0.id == id }) else { return }
        launchRoutine(routine, scheduled: now, now: now, advanceSchedule: false)
    }
    private func launchRoutine(_ routine: AssistantRoutine, scheduled: Date, now: Date, advanceSchedule: Bool = true) {
        let run = RoutineRun(routineID: routine.id, scheduledAt: scheduled, status: .running), expected = UUID()
        do { try commit { next in
            next.routineRuns.insert(run, at: 0); next.routineRuns = Array(next.routineRuns.prefix(500))
            if advanceSchedule, let index = next.routines.firstIndex(where: { $0.id == routine.id }) { next.routines[index].nextRunAt = routine.nextFire(after: now) }
        } } catch { fail(error); return }
        routineGeneration = expected
        routineTask = Task {
            defer { if routineGeneration == expected { routineTask = nil } }
            do {
                let client = try setupClient(address: state.settings.splashAddress, key: apiKey)
                var context = AgentContext(instructions: state.assistantInstructions, memories: state.memories, mailConnected: mailConnected, calendarConnected: calendarConnected, memoryLearning: false)
                context.mailProvider = state.settings.mailProvider
                context.externalConnectionsPaused = state.settings.networkDisabled
                context.profile = state.profile
                let tools: [AgentTool] = [.briefing, .tasks, .memories, .workContext] + (state.knowledgeDocuments.isEmpty ? [] : [.knowledge]) + (!state.settings.networkDisabled && mailConnected ? [.searchMail] : []) + (!state.settings.networkDisabled && calendarConnected ? [.calendar] : [])
                let result = try await LocalAgent(splash: client).respond(question: routine.prompt, history: [], context: context, tools: tools,
                    execute: { call in try await self.readRoutineTool(call, now: now) }, contextTokens: state.settings.contextTokens)
                try Task.checkCancellation(); guard routineGeneration == expected else { return }
                try commit { next in if let index = next.routineRuns.firstIndex(where: { $0.id == run.id }) {
                    next.routineRuns[index].status = .completed; next.routineRuns[index].result = result; next.routineRuns[index].finishedAt = Date()
                } }
            } catch {
                guard routineGeneration == expected else { return }
                do { try commit { next in if let index = next.routineRuns.firstIndex(where: { $0.id == run.id }) {
                    next.routineRuns[index].status = error is CancellationError ? .interrupted : .failed
                    next.routineRuns[index].result = error.localizedDescription; next.routineRuns[index].finishedAt = Date()
                } } } catch { fail(error) }
            }
        }
    }
    func pauseRoutineWork() {
        routineGeneration = UUID(); routineTask?.cancel(); routineTask = nil
        guard state.routineRuns.contains(where: { $0.status == .running }) else { return }
        do { try commit { next in for index in next.routineRuns.indices where next.routineRuns[index].status == .running {
            next.routineRuns[index].status = .interrupted; next.routineRuns[index].result = "Paused. This run will not replay automatically."; next.routineRuns[index].finishedAt = Date()
        } } } catch { fail(error) }
    }
}
