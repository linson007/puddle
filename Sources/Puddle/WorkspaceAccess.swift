import Foundation
import PuddleCore

extension PuddleStore {
    func workspaceAccess() throws -> UUID {
        guard !isLocked, !privateSession, !demo, storageAvailable else {
            throw PuddleError("Unlock Puddle, end the private session and load the saved workspace before continuing.")
        }
        return workspaceAccessRevision
    }
    func checkWorkspaceAccess(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard try workspaceAccess() == revision else {
            throw PuddleError("Workspace access changed while this operation was waiting. Start it again after reviewing the current workspace.")
        }
    }
    func writeWorkspaceExport(to url: URL, access: UUID, contents: @Sendable () async throws -> Data) async throws {
        try checkWorkspaceAccess(access)
        let data = try await contents()
        try checkWorkspaceAccess(access)
        guard url.isFileURL else { throw PuddleError("Choose a local export destination.") }
        // No suspension between the final access check and atomic publication.
        try WorkspaceBackup.write(data, to: url)
    }
}
