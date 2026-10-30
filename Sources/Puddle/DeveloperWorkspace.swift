import Combine
import Foundation
import PuddleCore

@MainActor final class DeveloperWorkspace: ObservableObject {
    @Published var selectedSessionID: UUID?
    @Published private(set) var drafts: [UUID: DevelopmentSession] = [:]
    @Published private(set) var inspection: ProjectInspectionResult?
    @Published private(set) var isInspecting = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func draft(_ session: DevelopmentSession) -> DevelopmentSession { drafts[session.id] ?? session }
    func edit(_ session: DevelopmentSession, _ change: (inout DevelopmentSession) -> Void) {
        var next = draft(session); change(&next); drafts[session.id] = next
    }
    func saved(_ id: UUID) { drafts[id] = nil }
    func detachProject(_ id: UUID, name: String?) {
        for key in drafts.keys where drafts[key]?.projectID == id { drafts[key]?.projectID = nil; drafts[key]?.projectName = name }
    }
    func inspect(_ request: ProjectInspectionRequest, project: DeveloperProject) {
        cancelInspection(); error = nil; isInspecting = true
        let expected = generation
        task = Task {
            do {
                let result = try await ProjectInspection.run(request, project: project)
                try Task.checkCancellation()
                guard generation == expected else { return }
                inspection = result; isInspecting = false
            } catch is CancellationError {}
            catch { if generation == expected { self.error = error.localizedDescription; isInspecting = false } }
        }
    }
    func cancelInspection() { generation = UUID(); task?.cancel(); task = nil; isInspecting = false; inspection = nil; error = nil }
    func reset() { cancelInspection(); selectedSessionID = nil; drafts = [:] }
}
