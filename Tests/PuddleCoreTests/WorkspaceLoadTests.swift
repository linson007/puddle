import Darwin
import Foundation
import XCTest
@testable import PuddleCore

/// Explicit synthetic endurance fixtures. Never reads a real workspace or account.
private final class LoadSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class WorkspaceLoadTests: XCTestCase {
    private struct Profile {
        let name: String, conversations: Int, lines: Int, characters: Int, memories: Int, tasks: Int, meetings: Int, activeLines: Int
        static let regular = Profile(name: "regular-six-month", conversations: 900, lines: 24, characters: 600, memories: 2000, tasks: 1500, meetings: 180, activeLines: 1)
        static let heavy = Profile(name: "heavy-six-month", conversations: 1800, lines: 60, characters: 600, memories: 5000, tasks: 5000, meetings: 360, activeLines: 1)
        static let long = Profile(name: "long-six-month", conversations: 20, lines: 24, characters: 600, memories: 5000, tasks: 5000, meetings: 60, activeLines: 108000)
    }
    private func snapshot(_ profile: Profile) -> AppSnapshot {
        var state = AppSnapshot()
        let now = Date(), paragraph = "Synthetic project planning, findings and follow-up notes. Review requirements and verify the saved work. "
        let padding = String(repeating: paragraph, count: profile.characters / paragraph.count + 1)
        state.settings.automaticallyLearn = false; state.settings.automaticallyCheck = false; state.settings.notifications = false
        state.conversations = (0..<profile.conversations).map { index in
            let lines = (0..<profile.lines).map { line in
                ChatLine(role: line.isMultiple(of: 2) ? "user" : "assistant", content: "Conversation \(index) message \(line). " + String(padding.prefix(profile.characters)))
            }
            return Conversation(createdAt: now.addingTimeInterval(-Double(index % 180) * 86400), lines: lines)
        }
        state.conversations[state.conversations.count - 1].lines[profile.lines - 1].content += " sixmonth-history-sentinel"
        state.memories = (0..<profile.memories).map { MemoryNote(title: "Preference \($0)", content: "Synthetic saved preference \($0). " + String(padding.prefix(220))) }
        state.memories.append(MemoryNote(title: "Your name", content: "Six Month Tester"))
        state.tasks = (0..<profile.tasks).map { index in
            var task = AssistantTask(title: "Six-month commitment \(index)")
            task.completed = index % 10 != 0; task.notes = String(padding.prefix(180)); return task
        }
        state.meetings = (0..<profile.meetings).map { index in
            var note = MeetingNote(title: "Synthetic meeting \(index)")
            note.transcript = String(repeating: "Meeting \(index): " + paragraph + "\n", count: 100)
            return note
        }
        state.chat = (0..<profile.activeLines).map { ChatLine(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Current six-month conversation message \($0). " + String(padding.prefix(profile.characters))) }
        return state
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    func testSixMonthWorkspaceLoadAndEndurance() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PUDDLE_LOAD_TESTS"] == "1" else { throw XCTSkip("Opt in with PUDDLE_LOAD_TESTS=1; uses large synthetic workspaces only") }
        let profile = environment["PUDDLE_LOAD_PROFILE"] == "heavy" ? Profile.heavy : environment["PUDDLE_LOAD_PROFILE"] == "long" ? Profile.long : Profile.regular
        var state = snapshot(profile)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-load-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = LoadSecrets(), store = EncryptedSnapshotStore(directory: directory, secrets: secrets)
        var metrics: [String: Any] = ["profile": profile.name, "conversations": profile.conversations, "archived_messages": profile.conversations * profile.lines, "active_messages": profile.activeLines, "memories": state.memories.count, "tasks": state.tasks.count, "meetings": state.meetings.count]
        func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try work()
            let seconds = ProcessInfo.processInfo.systemUptime - start
            metrics[name] = seconds; print("LOAD \(profile.name) \(name)=\(String(format: "%.6f", seconds))s")
            return value
        }
        let encoded = try measure("json_encode_seconds") { try JSONEncoder().encode(state) }
        metrics["json_bytes"] = encoded.count
        try measure("initial_save_seconds") { try store.save(state) }
        let restored = try measure("cold_load_seconds") { try EncryptedSnapshotStore(directory: directory, secrets: secrets).load() }
        XCTAssertEqual(restored.conversations.count, profile.conversations)
        XCTAssertTrue(restored.chat == state.chat, "The active transcript changed across storage pages")
        XCTAssertTrue(restored.conversations.last?.lines.last?.content.contains("sixmonth-history-sentinel") == true)
        var saves: [Double] = [], rss: [UInt64] = []
        let iterations = max(20, min(1000, Int(environment["PUDDLE_LOAD_ITERATIONS"] ?? "100") ?? 100))
        for index in 0..<iterations {
            state.tasks[0].title = "Edited commitment \(index)"
            state.chat.append(ChatLine(role: "assistant", content: "Synthetic appended reply \(index)"))
            let start = ProcessInfo.processInfo.systemUptime; try store.save(state)
            saves.append(ProcessInfo.processInfo.systemUptime - start); rss.append(residentBytes())
        }
        metrics["save_samples_seconds"] = saves; metrics["save_p50_seconds"] = saves.sorted()[saves.count / 2]
        let p95 = saves.sorted()[Int(ceil(Double(saves.count) * 0.95)) - 1]
        metrics["save_p95_seconds"] = p95; metrics["save_max_seconds"] = saves.max(); metrics["resident_samples_bytes"] = rss
        XCTAssertLessThan(p95, Double(environment["PUDDLE_LOAD_SAVE_BUDGET_MS"] ?? "100")! / 1000)
        XCTAssertLessThanOrEqual(Int64(rss.last!) - Int64(rss[5]), 64 * 1024 * 1024, "Resident growth after warmup exceeded 64 MB")
        let history = measure("history_late_search_seconds") { state.matchingConversations("sixmonth-history-sentinel") }
        XCTAssertEqual(history.count, 1)
        let search = measure("global_late_search_seconds") { WorkspaceSearch.search("sixmonth-history-sentinel", in: state) }
        XCTAssertEqual(search.count, 1)
        _ = measure("global_saturated_search_seconds") { WorkspaceSearch.search("Synthetic", in: state) }
        _ = measure("global_miss_search_seconds") { WorkspaceSearch.search("never-present-load-token", in: state) }
        let prompt = measure("prompt_preparation_seconds") { AgentContext(memories: state.memories).systemPrompt }
        XCTAssertTrue(prompt.contains("Six Month Tester")); XCTAssertLessThan(prompt.utf8.count, 100_000)
        measure("memory_update_seconds") { state.remember(title: "Preference \(profile.memories - 1)", content: "Edited last preference") }
        XCTAssertEqual(state.memories.count, profile.memories + 1)
        do {
            let backup = try measure("backup_encode_seconds") { try WorkspaceBackup.encode(state) }
            metrics["backup_bytes"] = backup.count
            let preview = try measure("backup_inspect_seconds") { try WorkspaceBackup.inspect(backup) }
            let merged = measure("backup_merge_seconds") { WorkspaceBackup.merging(preview, into: AppSnapshot()) }
            XCTAssertEqual(merged.0.conversations.count, profile.conversations + 1)
            let again = WorkspaceBackup.merging(preview, into: merged.0)
            XCTAssertEqual(again.1.conversationsAdded, 0)
        } catch { metrics["backup_error"] = error.localizedDescription; XCTFail("The six-month workspace could not be backed up: \(error)") }
        metrics["resident_final_bytes"] = residentBytes()
        if let output = environment["PUDDLE_LOAD_OUTPUT_DIRECTORY"] {
            let folder = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let run = environment["PUDDLE_LOAD_RUN"] ?? "result"
            try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("\(profile.name)-\(run).json"), options: .atomic)
            if environment["PUDDLE_LOAD_EXPORT_FIXTURE"] == "1" {
                let file = folder.appendingPathComponent("\(profile.name)-fixture.json")
                try encoded.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        print("LOAD SUMMARY " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
}
