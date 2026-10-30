import CryptoKit
import Compression
import Foundation

fileprivate struct WorkspaceContent: Codable, Sendable {
    let schemaVersion: Int
    let profileLibrary: AssistantProfileLibrary
    let memories: [MemoryNote]
    let tasks: [AssistantTask]
    let meetings: [MeetingNote]
    let conversations: [Conversation]
    let assistantInstructions: String
    let developmentSessions: [DevelopmentSession]
    let actionProposals: [ActionProposal]
    let browserErrands: [BrowserErrand]
    let routines: [AssistantRoutine]
    let routineRuns: [RoutineRun]
    let workProjects: [WorkProject]
    let people: [PersonContext]
    let workDecisions: [WorkDecision]
    init(_ snapshot: AppSnapshot) {
        schemaVersion = AppSnapshot.currentSchemaVersion; profileLibrary = snapshot.profileLibrary
        memories = snapshot.memories; tasks = snapshot.tasks; meetings = snapshot.meetings
        conversations = snapshot.conversationHistory; assistantInstructions = snapshot.assistantInstructions
        actionProposals = snapshot.actionProposals
        browserErrands = snapshot.browserErrands; routines = snapshot.routines; routineRuns = snapshot.routineRuns
        workProjects = snapshot.workProjects; people = snapshot.people; workDecisions = snapshot.workDecisions
        developmentSessions = snapshot.developmentSessions.map { session in
            var copy = session
            if let id = copy.projectID { copy.projectName = snapshot.developerProjects.first { $0.id == id }?.name ?? copy.projectName }
            copy.projectID = nil; return copy
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, profileLibrary, memories, tasks, meetings, conversations, assistantInstructions, developmentSessions, actionProposals, browserErrands, routines, routineRuns, workProjects, people, workDecisions }
    private enum LegacyProfileKey: String, CodingKey { case profile }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        if let library = try values.decodeIfPresent(AssistantProfileLibrary.self, forKey: .profileLibrary) { profileLibrary = library }
        else {
            let legacy = try decoder.container(keyedBy: LegacyProfileKey.self)
            profileLibrary = AssistantProfileLibrary(legacyContext: try legacy.decodeIfPresent(ExecutiveProfile.self, forKey: .profile) ?? ExecutiveProfile())
        }
        memories = try values.decode([MemoryNote].self, forKey: .memories)
        tasks = try values.decode([AssistantTask].self, forKey: .tasks)
        meetings = try values.decode([MeetingNote].self, forKey: .meetings)
        conversations = try values.decode([Conversation].self, forKey: .conversations)
        assistantInstructions = try values.decode(String.self, forKey: .assistantInstructions)
        developmentSessions = try values.decodeIfPresent([DevelopmentSession].self, forKey: .developmentSessions) ?? []
        actionProposals = try values.decodeIfPresent([ActionProposal].self, forKey: .actionProposals) ?? []
        browserErrands = try values.decodeIfPresent([BrowserErrand].self, forKey: .browserErrands) ?? []
        routines = try values.decodeIfPresent([AssistantRoutine].self, forKey: .routines) ?? []
        routineRuns = try values.decodeIfPresent([RoutineRun].self, forKey: .routineRuns) ?? []
        workProjects = try values.decodeIfPresent([WorkProject].self, forKey: .workProjects) ?? []
        people = try values.decodeIfPresent([PersonContext].self, forKey: .people) ?? []
        workDecisions = try values.decodeIfPresent([WorkDecision].self, forKey: .workDecisions) ?? []
    }
}

public struct WorkspaceBackupPreview: Sendable {
    public let createdAt: Date
    fileprivate let content: WorkspaceContent
    public var memoriesCount: Int { content.memories.count }
    public var tasksCount: Int { content.tasks.count }
    public var meetingsCount: Int { content.meetings.count }
    public var conversationsCount: Int { content.conversations.count }
    public var profilesCount: Int { content.profileLibrary.profiles.count }
    public var developmentSessionsCount: Int { content.developmentSessions.count }
    public var actionsCount: Int { content.actionProposals.count }
    public var routinesCount: Int { content.routines.count }
    public var errandsCount: Int { content.browserErrands.count }
    public var projectsCount: Int { content.workProjects.count }
    public var peopleCount: Int { content.people.count }
    public var decisionsCount: Int { content.workDecisions.count }
}

public struct WorkspaceRestoreReport: Equatable, Sendable {
    public var memoriesAdded = 0
    public var tasksAdded = 0
    public var meetingsAdded = 0
    public var conversationsAdded = 0
    public var skipped = 0
    public var profilesRestored = 0
    public var profilesKept = 0
    public var developmentSessionsAdded = 0
    public var actionsAdded = 0
    public var routinesAdded = 0
    public var errandsAdded = 0
    public var projectsAdded = 0
    public var peopleAdded = 0
    public var decisionsAdded = 0
    public var summary: String {
        "Added \(memoriesAdded) memories, \(tasksAdded) commitments, \(meetingsAdded) meeting notes, \(conversationsAdded) conversations, \(actionsAdded) actions, \(projectsAdded) projects, \(peopleAdded) people, \(decisionsAdded) decisions, \(routinesAdded) routines, \(errandsAdded) browser errands and \(developmentSessionsAdded) development sessions. Kept \(skipped) existing or over-limit items. Restored \(profilesRestored) profiles; kept \(profilesKept) current or conflicting profiles."
    }
}

/// Portable local work only. Credentials and cached connected-account data never enter this format.
public enum WorkspaceBackup {
    public static let maximumBytes = 64 * 1024 * 1024
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let createdAt: Date
        let payload: Data
        let sha256: String
        let compression: String?
        let uncompressedBytes: Int?
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func encode(_ snapshot: AppSnapshot, now: Date = Date()) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(WorkspaceContent(snapshot))
        guard payload.count <= TranscriptVault.maximumBytes else { throw PuddleError("This workspace exceeds the 120 MB logical backup limit. Export large transcripts separately.") }
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        let data = try encoder.encode(Envelope(format: "puddle-workspace", version: 2, createdAt: now, payload: compressed, sha256: digest(compressed), compression: "lzfse", uncompressedBytes: payload.count))
        guard data.count <= maximumBytes else { throw PuddleError("This workspace exceeds the 64 MB portable backup limit. Export large meeting transcripts separately.") }
        return data
    }

    public static func inspect(_ data: Data) throws -> WorkspaceBackupPreview {
        guard data.count <= maximumBytes else { throw PuddleError("Choose a Puddle backup under 64 MB.") }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw PuddleError("This file is not a readable Puddle workspace backup. Your current workspace has not changed.") }
        guard envelope.format == "puddle-workspace", (1...2).contains(envelope.version) else {
            throw PuddleError("This backup format is unsupported. Open it with a compatible version of Puddle.")
        }
        guard envelope.sha256 == digest(envelope.payload) else {
            throw PuddleError("The backup failed its integrity check. Choose an intact backup; your workspace has not changed.")
        }
        let payload: Data
        if envelope.version == 1 { payload = envelope.payload }
        else {
            guard envelope.compression == "lzfse", let size = envelope.uncompressedBytes,
                  (1...TranscriptVault.maximumBytes).contains(size), !envelope.payload.isEmpty else { throw PuddleError("The compressed backup has invalid size or encoding details.") }
            // Allocate only a validated logical size. Never use an unbounded
            // decompressor on a file supplied for restore.
            var decoded = Data(count: size + 1)
            let count = decoded.withUnsafeMutableBytes { output in
                envelope.payload.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == size else { throw PuddleError("The compressed backup is damaged or has an invalid decoded size.") }
            decoded.count = size; payload = decoded
        }
        let content = try JSONDecoder().decode(WorkspaceContent.self, from: payload)
        guard (4...AppSnapshot.currentSchemaVersion).contains(content.schemaVersion) else { throw SnapshotVersionError() }
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        guard unique(content.memories.map(\.id)), unique(content.tasks.map(\.id)), unique(content.meetings.map(\.id)),
              unique(content.workProjects.map(\.id)), unique(content.people.map(\.id)), unique(content.workDecisions.map(\.id)),
              content.workProjects.count <= 5000, content.people.count <= 10000, content.workDecisions.count <= 10000,
              unique(content.browserErrands.map(\.id)), unique(content.routines.map(\.id)), unique(content.routineRuns.map(\.id)),
              unique(content.actionProposals.map(\.id)), content.actionProposals.count <= 5000,
              unique(content.conversations.map(\.id)), unique(content.developmentSessions.map(\.id)), content.developmentSessions.count <= 500 else { throw PuddleError("The backup contains repeated identifiers or too many development sessions and cannot be merged safely.") }
        for task in content.tasks { _ = try TaskDraft(task).applying(to: task) }
        for note in content.meetings { _ = try MeetingDraft(note).applying(to: note) }
        for session in content.developmentSessions { _ = try session.validated() }
        for routine in content.routines { _ = try routine.validated() }
        for project in content.workProjects { _ = try project.validated() }
        for person in content.people { _ = try person.validated() }
        for decision in content.workDecisions { _ = try decision.validated() }
        guard content.assistantInstructions.count <= 4000,
              content.memories.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 200 && $0.content.count <= 4000 }),
              content.conversations.allSatisfy({ unique($0.lines.map(\.id)) && $0.lines.allSatisfy { ["user", "assistant"].contains($0.role) } }) else {
            throw PuddleError("The backup has invalid workspace content. Your workspace has not changed.")
        }
        return WorkspaceBackupPreview(createdAt: envelope.createdAt, content: content)
    }

    public static func merging(_ backup: WorkspaceBackupPreview, into current: AppSnapshot, now: Date = Date()) -> (AppSnapshot, WorkspaceRestoreReport) {
        var next = current, report = WorkspaceRestoreReport()
        var projectIDs = Set(current.workProjects.map(\.id))
        for project in backup.content.workProjects {
            guard next.workProjects.count < 5000, projectIDs.insert(project.id).inserted else { report.skipped += 1; continue }
            next.workProjects.append(project); report.projectsAdded += 1
        }
        var peopleIDs = Set(current.people.map(\.id))
        for person in backup.content.people {
            guard next.people.count < 10000, peopleIDs.insert(person.id).inserted else { report.skipped += 1; continue }
            next.people.append(person); report.peopleAdded += 1
        }
        var decisionIDs = Set(current.workDecisions.map(\.id))
        for var decision in backup.content.workDecisions {
            guard next.workDecisions.count < 10000, decisionIDs.insert(decision.id).inserted else { report.skipped += 1; continue }
            if let id = decision.projectID, !projectIDs.contains(id) { decision.projectID = nil }
            next.workDecisions.append(decision); report.decisionsAdded += 1
        }
        var routineIDs = Set(current.routines.map(\.id))
        for var routine in backup.content.routines {
            guard next.routines.count < 50, routineIDs.insert(routine.id).inserted else { report.skipped += 1; continue }
            routine.enabled = false; routine.nextRunAt = nil; next.routines.append(routine); report.routinesAdded += 1
        }
        var runIDs = Set(current.routineRuns.map(\.id))
        for var run in backup.content.routineRuns where next.routineRuns.count < 500 {
            guard runIDs.insert(run.id).inserted else { continue }
            if run.status == .running { run.status = .interrupted; run.result = "Restored interrupted run. No automatic replay." }
            next.routineRuns.append(run)
        }
        var errandIDs = Set(current.browserErrands.map(\.id))
        for var job in backup.content.browserErrands {
            guard errandIDs.insert(job.id).inserted else { report.skipped += 1; continue }
            if job.status == .running { job.status = .paused }
            next.browserErrands.append(job); report.errandsAdded += 1
        }
        var actionIDs = Set(current.actionProposals.map(\.id))
        for var action in backup.content.actionProposals {
            guard actionIDs.insert(action.id).inserted else { report.skipped += 1; continue }
            if action.status == .dispatching { action.status = .uncertain; action.detail = "Restored an interrupted action. Check its provider before taking further action." }
            // Imported proposals always require a fresh exact-content review.
            action.authorizedDigest = nil
            next.actionProposals.append(action); report.actionsAdded += 1
        }
        var memoryIDs = Set(current.memories.map(\.id)), memoryTitles = Set(current.memories.map { MemoryLearning.identity($0.title) })
        for memory in backup.content.memories {
            if memoryIDs.contains(memory.id) || memoryTitles.contains(MemoryLearning.identity(memory.title)) { report.skipped += 1; continue }
            next.memories.append(memory); memoryIDs.insert(memory.id); memoryTitles.insert(MemoryLearning.identity(memory.title)); report.memoriesAdded += 1
        }
        var taskIDs = Set(current.tasks.map(\.id))
        for var task in backup.content.tasks {
            guard taskIDs.insert(task.id).inserted else { report.skipped += 1; continue }
            task.focusDate = nil
            if let id = task.projectID, !projectIDs.contains(id) { task.projectID = nil }
            // Imported overdue work stays visible without replaying old reminder notifications.
            if let due = task.dueAt, due <= now { task.notifiedAt = now }
            next.tasks.append(task); report.tasksAdded += 1
        }
        var meetingIDs = Set(current.meetings.map(\.id))
        for var note in backup.content.meetings {
            guard meetingIDs.insert(note.id).inserted else { report.skipped += 1; continue }
            if let id = note.projectID, !projectIDs.contains(id) { note.projectID = nil }
            next.meetings.append(note); report.meetingsAdded += 1
        }
        var conversationIDs = Set(current.conversationHistory.map(\.id)); conversationIDs.insert(current.currentConversationID)
        for conversation in backup.content.conversations {
            guard conversationIDs.insert(conversation.id).inserted else { report.skipped += 1; continue }
            next.conversations.append(conversation); report.conversationsAdded += 1
        }
        let needsContext = current.profile == ExecutiveProfile()
        var library = current.profileLibrary
        for profile in backup.content.profileLibrary.profiles {
            if let existing = library.profiles.first(where: { $0.id == profile.id }) {
                if existing.context == ExecutiveProfile(), profile.context != ExecutiveProfile(), (try? library.update(profile)) != nil {
                    report.profilesRestored += 1
                } else { report.profilesKept += 1 }
            } else if (try? library.add(profile, activate: false)) != nil { report.profilesRestored += 1 }
            else { report.profilesKept += 1 }
        }
        if needsContext, backup.content.profileLibrary.active.context != ExecutiveProfile() {
            try? library.activate(backup.content.profileLibrary.activeID)
        }
        next.profileLibrary = library
        var sessionIDs = Set(current.developmentSessions.map(\.id))
        for var session in backup.content.developmentSessions {
            guard next.developmentSessions.count < 500, sessionIDs.insert(session.id).inserted else { report.skipped += 1; continue }
            session.projectID = nil; next.developmentSessions.append(session); report.developmentSessionsAdded += 1
        }
        if current.assistantInstructions == AppSnapshot().assistantInstructions { next.assistantInstructions = backup.content.assistantInstructions }
        return (next, report)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(_ url: URL) throws -> WorkspaceBackupPreview {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= maximumBytes else {
            throw PuddleError("Choose a regular Puddle backup file under 64 MB.")
        }
        return try inspect(Data(contentsOf: url))
    }
}
