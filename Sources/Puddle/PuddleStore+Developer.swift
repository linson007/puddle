import AppKit
import Foundation
import PuddleCore

extension PuddleStore {
    func chooseDeveloperProfile() {
        if let profile = state.profileLibrary.profiles.first(where: { $0.kind == .developer }) { switchAssistantProfile(profile.id) }
        else { saveAssistantProfile(AssistantProfile(kind: .developer, title: state.profileLibrary.availableTitle("Developer")), isNew: true) }
    }
    func chooseDeveloperFolder(reconnecting id: UUID? = nil) async {
        guard !demo else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose one project folder for source browsing and local AI context. Common private/generated paths are excluded. Puddle will not modify project files or execute project code."
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url, !demo else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let bookmark = try canonical.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let existing = id.flatMap { target in state.developerProjects.first { $0.id == target } } ?? state.developerProjects.first { $0.path == canonical.path }
            guard id == nil || existing?.id == id else { throw PuddleError("This project connection was removed. Choose Folder to create a new connection.") }
            let project = DeveloperProject(id: existing?.id ?? UUID(), name: existing?.name ?? canonical.lastPathComponent,
                path: canonical.path, bookmark: bookmark, context: existing?.context ?? "")
            _ = try ProjectFiles(project: project)
            _ = saveDeveloperProject(project, isNew: existing == nil, reconnecting: id != nil)
        } catch { fail(error) }
    }
    @discardableResult func saveDeveloperProject(_ project: DeveloperProject, isNew: Bool = false, reconnecting: Bool = false) -> Bool {
        do {
            let next = try project.validated()
            guard isNew || state.developerProjects.contains(where: { $0.id == project.id }) else { throw PuddleError("This project connection was removed. Your draft has been retained.") }
            guard !state.developerProjects.contains(where: { $0.id != next.id && $0.path == next.path }) else { throw PuddleError("This folder is already connected. Choose its existing project entry.") }
            let changed = state.activeDeveloperProjectID != next.id
            guard state.developerProjects.count < 25 || state.developerProjects.contains(where: { $0.id == project.id }) else { throw PuddleError("Keep up to 25 connected projects. Remove an unused connection first.") }
            if let previous = state.developerProjects.first(where: { $0.id == next.id }), previous.path != next.path, !reconnecting {
                throw PuddleError("Reconnect project folders with Choose Folder rather than changing a saved path.")
            }
            try commit { snapshot in
                if let index = snapshot.developerProjects.firstIndex(where: { $0.id == next.id }) { snapshot.developerProjects[index] = next }
                else { snapshot.developerProjects.append(next) }
                snapshot.activeDeveloperProjectID = next.id
            }
            stopAI(); developerWorkspace.cancelInspection()
            if changed { developerWorkspace.selectedSessionID = nil }
            if state.profileLibrary.active.kind == .developer, !demo { developerWorkspace.inspect(.files(""), project: next) }
            errorMessage = nil; return true
        } catch { fail(error); return false }
    }
    @discardableResult func selectDeveloperProject(_ id: UUID?) -> Bool {
        guard id != state.activeDeveloperProjectID else { return true }
        guard id == nil || state.developerProjects.contains(where: { $0.id == id }) else { return false }
        do {
            try commit { $0.activeDeveloperProjectID = id }
            stopAI(); developerWorkspace.cancelInspection(); developerWorkspace.selectedSessionID = nil; errorMessage = nil; return true
        } catch { fail(error); return false }
    }
    func removeDeveloperProject(_ id: UUID) {
        do {
            let name = state.developerProjects.first { $0.id == id }?.name
            try commit { snapshot in
                snapshot.developerProjects.removeAll { $0.id == id }
                if snapshot.activeDeveloperProjectID == id { snapshot.activeDeveloperProjectID = nil }
                for index in snapshot.developmentSessions.indices where snapshot.developmentSessions[index].projectID == id {
                    snapshot.developmentSessions[index].projectName = name
                    snapshot.developmentSessions[index].projectID = nil
                }
            }
            developerWorkspace.detachProject(id, name: name)
            stopAI(); developerWorkspace.cancelInspection(); errorMessage = nil
        } catch { fail(error) }
    }
    @discardableResult func createDevelopmentSession(kind: DevelopmentSessionKind) -> UUID? {
        let session = DevelopmentSession(projectID: state.activeDeveloperProjectID, title: kind.title, kind: kind)
        guard saveDevelopmentSession(session, isNew: true) else { return nil }
        developerWorkspace.selectedSessionID = session.id; return session.id
    }
    @discardableResult func saveDevelopmentSession(_ session: DevelopmentSession, isNew: Bool = false) -> Bool {
        do {
            var next = try session.validated()
            if let id = next.projectID {
                guard let project = state.developerProjects.first(where: { $0.id == id }) else { throw PuddleError("Reconnect or choose a project before linking this session.") }
                next.projectName = project.name
            }
            guard isNew || state.developmentSessions.contains(where: { $0.id == next.id }) else { throw PuddleError("This session was removed. Your draft has been retained.") }
            guard !isNew || state.developmentSessions.count < 500 else { throw PuddleError("Keep up to 500 development sessions. Remove an unused session first.") }
            try commit { snapshot in
                if let index = snapshot.developmentSessions.firstIndex(where: { $0.id == next.id }) { snapshot.developmentSessions[index] = next }
                else { snapshot.developmentSessions.insert(next, at: 0) }
            }
            developerWorkspace.saved(next.id); errorMessage = nil; return true
        } catch { fail(error); return false }
    }
    func deleteDevelopmentSession(_ id: UUID) {
        do {
            try commit { $0.developmentSessions.removeAll { $0.id == id } }
            developerWorkspace.saved(id)
            if developerWorkspace.selectedSessionID == id { developerWorkspace.selectedSessionID = nil }
        } catch { fail(error) }
    }
}
