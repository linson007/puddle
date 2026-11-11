import Foundation
import PuddleCore

extension PuddleStore {
    func showTasks(_ filter: TaskFilter = .open) {
        taskFilter = filter; section = .tasks
    }

    @discardableResult func saveProfile(_ profile: ExecutiveProfile) async -> Bool {
        do {
            let validated = try profile.validated()
            try await commit { $0.profile = validated }
            await stopAI()
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func switchAssistantProfile(_ id: UUID) async -> Bool {
        guard id != state.profileLibrary.activeID else { return true }
        do {
            var library = state.profileLibrary; try library.activate(id)
            try await commit { $0.profileLibrary = library }
            updateProfileNavigation()
            await stopAI(); developerWorkspace.cancelInspection(); errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func saveAssistantProfile(_ profile: AssistantProfile, isNew: Bool) async -> Bool {
        do {
            var library = state.profileLibrary
            if isNew { try library.add(profile) } else { try library.update(profile) }
            try await commit { $0.profileLibrary = library }
            updateProfileNavigation()
            if isNew || profile.id == state.profileLibrary.activeID { await stopAI(); developerWorkspace.cancelInspection() }
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    private func updateProfileNavigation() {
        if section == .developer, state.profileLibrary.active.kind != .developer { section = .today }
    }

    @discardableResult func duplicateAssistantProfile(_ id: UUID) async -> Bool {
        guard let source = state.profileLibrary.profiles.first(where: { $0.id == id }) else { return false }
        let copy = AssistantProfile(kind: source.kind, title: state.profileLibrary.availableTitle("\(source.title) copy"),
            context: source.context, additionalGuidance: source.additionalGuidance)
        return await saveAssistantProfile(copy, isNew: true)
    }

    @discardableResult func deleteAssistantProfile(_ id: UUID) async -> Bool {
        do {
            var library = state.profileLibrary; try library.remove(id)
            try await commit { $0.profileLibrary = library }
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func saveCommitment(_ draft: TaskDraft, taskID: UUID? = nil) async -> Bool {
        do {
            let original: AssistantTask
            if let taskID {
                guard let existing = state.tasks.first(where: { $0.id == taskID }) else {
                    throw PuddleError("This commitment was removed. Your draft has been retained.")
                }
                original = existing
            } else { original = AssistantTask(title: draft.title) }
            var next = try draft.applying(to: original)
            if let id = next.projectID, !state.workProjects.contains(where: { $0.id == id }) { next.projectID = nil }
            try await commit { snapshot in
                if let index = snapshot.tasks.firstIndex(where: { $0.id == next.id }) { snapshot.tasks[index] = next }
                else { snapshot.tasks.append(next) }
            }
            scheduleReminders(); errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    func setDailyPriority(_ id: UUID, enabled: Bool, now: Date = Date()) async {
        do {
            var next = state
            try next.setDailyPriority(id, enabled: enabled, now: now)
            try await commit { $0.tasks = next.tasks }
            errorMessage = nil
        } catch { fail(error) }
    }
}
