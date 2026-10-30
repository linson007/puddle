import Foundation
import PuddleCore

extension PuddleStore {
    @discardableResult func saveProfile(_ profile: ExecutiveProfile) -> Bool {
        do {
            let validated = try profile.validated()
            try commit { $0.profile = validated }
            stopAI()
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func switchAssistantProfile(_ id: UUID) -> Bool {
        guard id != state.profileLibrary.activeID else { return true }
        do {
            var library = state.profileLibrary; try library.activate(id)
            try commit { $0.profileLibrary = library }
            updateProfileNavigation()
            stopAI(); developerWorkspace.cancelInspection(); errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func saveAssistantProfile(_ profile: AssistantProfile, isNew: Bool) -> Bool {
        do {
            var library = state.profileLibrary
            if isNew { try library.add(profile) } else { try library.update(profile) }
            try commit { $0.profileLibrary = library }
            updateProfileNavigation()
            if isNew || profile.id == state.profileLibrary.activeID { stopAI(); developerWorkspace.cancelInspection() }
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    private func updateProfileNavigation() {
        if section == .developer, state.profileLibrary.active.kind != .developer { section = .today }
    }

    @discardableResult func duplicateAssistantProfile(_ id: UUID) -> Bool {
        guard let source = state.profileLibrary.profiles.first(where: { $0.id == id }) else { return false }
        let copy = AssistantProfile(kind: source.kind, title: state.profileLibrary.availableTitle("\(source.title) copy"),
            context: source.context, additionalGuidance: source.additionalGuidance)
        return saveAssistantProfile(copy, isNew: true)
    }

    @discardableResult func deleteAssistantProfile(_ id: UUID) -> Bool {
        do {
            var library = state.profileLibrary; try library.remove(id)
            try commit { $0.profileLibrary = library }
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    @discardableResult func saveCommitment(_ draft: TaskDraft, taskID: UUID? = nil) -> Bool {
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
            try commit { snapshot in
                if let index = snapshot.tasks.firstIndex(where: { $0.id == next.id }) { snapshot.tasks[index] = next }
                else { snapshot.tasks.append(next) }
            }
            scheduleReminders(); errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    func setDailyPriority(_ id: UUID, enabled: Bool, now: Date = Date()) {
        do {
            var next = state
            try next.setDailyPriority(id, enabled: enabled, now: now)
            try commit { $0.tasks = next.tasks }
            errorMessage = nil
        } catch { fail(error) }
    }
}
