import CryptoKit
import Foundation
import XCTest
@testable import PuddleCore

final class AssistantProfileTests: XCTestCase {
    func testPresetsHaveStableUniqueIDsAndPersonalIsDefault() throws {
        let library = AssistantProfileLibrary(), again = AssistantProfileLibrary()
        XCTAssertEqual(library.active.kind, .personal)
        XCTAssertEqual(library.profiles.map(\.kind), [.personal, .developer])
        XCTAssertEqual(AssistantProfileKind.allCases, [.personal, .developer, .custom])
        XCTAssertEqual(library.profiles.map(\.id), again.profiles.map(\.id))
        XCTAssertEqual(Set(library.profiles.map(\.id)).count, 2)
        XCTAssertEqual(library.profiles.map(\.id.uuidString), [1, 3].map { "54A8D675-2837-42F1-B7D0-00000000000\($0)" })
        XCTAssertEqual(try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONEncoder().encode(library)), library)
    }

    private let retiredPresets: [(kind: String, title: String, id: UUID)] = [
        ("cxo", "CXO", UUID(uuidString: "54A8D675-2837-42F1-B7D0-000000000002")!),
        ("productManager", "Product Manager", UUID(uuidString: "54A8D675-2837-42F1-B7D0-000000000004")!),
        ("researcher", "Researcher", UUID(uuidString: "54A8D675-2837-42F1-B7D0-000000000005")!)
    ]

    private func savedProfile(_ profile: AssistantProfile, kind: String) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        object["kind"] = kind
        return object
    }

    func testEmptyRetiredPresetsAreRemovedWithoutChangingSharedWorkspace() throws {
        var snapshot = AppSnapshot()
        snapshot.tasks = [AssistantTask(title: "Keep my work")]
        snapshot.chat = [ChatLine(role: "user", content: "Keep my conversation")]
        snapshot.remember(title: "Style", content: "Concise")
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        for retired in retiredPresets {
            var object = original
            var library = object["profileLibrary"] as! [String: Any]
            var entries = library["profiles"] as! [[String: Any]]
            for preset in retiredPresets {
                entries.append(try savedProfile(AssistantProfile(id: preset.id, title: preset.title), kind: preset.kind))
            }
            library["profiles"] = entries; library["activeID"] = retired.id.uuidString
            object["profileLibrary"] = library
            let migrated = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(migrated.profileLibrary, snapshot.profileLibrary)
            XCTAssertEqual(migrated.tasks, snapshot.tasks)
            XCTAssertEqual(migrated.chat, snapshot.chat)
            XCTAssertEqual(migrated.memories, snapshot.memories)
        }
    }

    func testEditedAndUserCreatedRetiredProfilesBecomeCustomAndKeepSelection() throws {
        var context = ExecutiveProfile(); context.objectives = "Compare customer interviews"
        for retired in retiredPresets {
            let profiles = [
                AssistantProfile(id: retired.id, title: retired.title, context: context),
                AssistantProfile(id: retired.id, title: retired.title, additionalGuidance: "Use my supplied sources"),
                AssistantProfile(id: retired.id, title: "My saved approach"),
                AssistantProfile(title: retired.title)
            ]
            for profile in profiles {
                var library = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AssistantProfileLibrary())) as! [String: Any]
                library["profiles"] = (library["profiles"] as! [[String: Any]]) + [try savedProfile(profile, kind: retired.kind)]
                library["activeID"] = profile.id.uuidString
                let migrated = try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONSerialization.data(withJSONObject: library))
                XCTAssertEqual(migrated.profiles.count, 3)
                XCTAssertEqual(migrated.active, profile)
                XCTAssertEqual(migrated.active.kind, .custom)
                XCTAssertEqual(try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONEncoder().encode(migrated)), migrated)
            }
        }
    }

    func testRemovingLastRetiredPresetCreatesPersonalFallbackAndUnknownKindsStillFail() throws {
        for retired in retiredPresets {
            let profile = AssistantProfile(id: retired.id, title: retired.title)
            let library: [String: Any] = ["profiles": [try savedProfile(profile, kind: retired.kind)], "activeID": profile.id.uuidString]
            let migrated = try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONSerialization.data(withJSONObject: library))
            XCTAssertEqual(migrated.profiles.count, 1)
            XCTAssertEqual(migrated.active.kind, .personal)
            XCTAssertEqual(migrated.active.id, AssistantProfileLibrary().activeID)
        }
        let unknown = try savedProfile(AssistantProfile(), kind: "unsupportedFutureRole")
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantProfile.self, from: JSONSerialization.data(withJSONObject: unknown)))
    }

    func testLegacyBackupDropsEmptyRetiredPresetsAndRestoresSavedContextAsCustom() throws {
        for saved in retiredPresets {
            var envelope = try JSONSerialization.jsonObject(with: WorkspaceBackup.encode(AppSnapshot())) as! [String: Any]
            let compressed = Data(base64Encoded: envelope["payload"] as! String)!
            let plain = try (compressed as NSData).decompressed(using: .lzfse) as Data
            var payload = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            var library = payload["profileLibrary"] as! [String: Any]
            var entries = library["profiles"] as! [[String: Any]]
            var context = ExecutiveProfile(); context.objectives = "Verify the supplied evidence"
            let expected = try AssistantProfile(id: saved.id, title: saved.title, context: context, additionalGuidance: "Cite interview notes").validated()
            for retired in retiredPresets {
                let profile = retired.id == saved.id ? expected : AssistantProfile(id: retired.id, title: retired.title)
                entries.append(try savedProfile(profile, kind: retired.kind))
            }
            library["profiles"] = entries; library["activeID"] = expected.id.uuidString
            payload["profileLibrary"] = library
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            envelope["payload"] = bytes.base64EncodedString()
            envelope["version"] = 1; envelope.removeValue(forKey: "compression"); envelope.removeValue(forKey: "uncompressedBytes")
            envelope["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let preview = try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: envelope))
            XCTAssertEqual(preview.profilesCount, 3)
            let (restored, report) = WorkspaceBackup.merging(preview, into: AppSnapshot())
            XCTAssertEqual(report.profilesRestored, 1)
            XCTAssertEqual(restored.profileLibrary.active, expected)
            let repeated = WorkspaceBackup.merging(preview, into: restored).0
            XCTAssertEqual(repeated.profileLibrary, restored.profileLibrary)
        }
    }

    func testLegacyWorkContextMigratesWithoutLosingSavedFieldsOrChat() throws {
        var legacy = ExecutiveProfile(); legacy.name = "Mira"; legacy.role = "COO"; legacy.organization = "Studio"
        legacy.objectives = "Improve delivery"; legacy.configured = true
        let profileObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        var old = AppSnapshot(); old.tasks = [AssistantTask(title: "Current work")]; old.chat = [ChatLine(role: "user", content: "Saved discussion")]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["schemaVersion"] = 4; object["profile"] = profileObject; object.removeValue(forKey: "profileLibrary")
        let migrated = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.profile, legacy); XCTAssertEqual(migrated.profileLibrary.active.kind, .personal)
        XCTAssertEqual(migrated.tasks, old.tasks); XCTAssertEqual(migrated.chat, old.chat)
        let roundTrip = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(roundTrip.profileLibrary, migrated.profileLibrary)
    }

    func testRoleSwitchKeepsIndependentContextsAndSharedWorkspace() throws {
        var snapshot = AppSnapshot()
        var context = ExecutiveProfile(); context.name = "Mira"; context.objectives = "Executive objective"
        snapshot.profile = try context.validated()
        let personalID = snapshot.profileLibrary.activeID
        let developerID = snapshot.profileLibrary.profiles.first { $0.kind == .developer }!.id
        snapshot.tasks = [AssistantTask(title: "Shared task")]; snapshot.remember(title: "Style", content: "Concise")
        snapshot.chat = [ChatLine(role: "user", content: "Shared chat")]
        try snapshot.profileLibrary.activate(developerID)
        snapshot.profile.objectives = "Ship the API"
        XCTAssertEqual(snapshot.tasks.count, 1); XCTAssertEqual(snapshot.memories.count, 1); XCTAssertEqual(snapshot.chat.count, 1)
        try snapshot.profileLibrary.activate(personalID); XCTAssertEqual(snapshot.profile.objectives, "Executive objective")
        try snapshot.profileLibrary.activate(developerID); XCTAssertEqual(snapshot.profile.objectives, "Ship the API")
    }

    func testCustomGuidanceValidationDuplicateNamesAndStaleEdits() throws {
        var library = AssistantProfileLibrary()
        var custom = AssistantProfile(kind: .custom, title: "  Client   Work ", additionalGuidance: "Prefer concrete examples")
        try library.add(custom)
        XCTAssertEqual(library.active.title, "Client Work")
        XCTAssertThrowsError(try library.add(AssistantProfile(title: "client work")))
        custom.title = "Consulting"; custom.additionalGuidance = String(repeating: "x", count: 4001)
        XCTAssertThrowsError(try library.update(custom))
        custom.additionalGuidance = "Keep recommendations actionable"; try library.update(custom)
        let personalID = library.profiles.first { $0.kind == .personal }!.id
        XCTAssertThrowsError(try library.remove(custom.id))
        try library.activate(personalID); try library.remove(custom.id)
        XCTAssertThrowsError(try library.update(custom)); XCTAssertThrowsError(try library.activate(custom.id))
    }

    func testLibraryRejectsEmptyDuplicateAndMissingActiveSelection() throws {
        let valid = AssistantProfileLibrary()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        object["profiles"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONSerialization.data(withJSONObject: object)))
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        object["activeID"] = UUID().uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONSerialization.data(withJSONObject: object)))
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        let entries = object["profiles"] as! [[String: Any]]; object["profiles"] = [entries[0], entries[0]]
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantProfileLibrary.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testProfileLimitAndCopyTitlesRemainUsable() throws {
        var library = AssistantProfileLibrary()
        for number in 1...(AssistantProfileLibrary.maximumCount - library.profiles.count) {
            try library.add(AssistantProfile(title: "Custom \(number)"), activate: false)
        }
        XCTAssertEqual(library.profiles.count, 50)
        XCTAssertThrowsError(try library.add(AssistantProfile(title: "Too many")))
        XCTAssertEqual(library.availableTitle("Developer"), "Developer 2")
    }

    func testDeveloperPromptUsesSelectedGuidanceAndDoesNotAssumeExecutionAccess() {
        var context = AgentContext(); context.profileKind = .developer; context.profileName = "API Developer"
        context.profileGuidance = "Prefer Swift and concise examples"
        let prompt = context.systemPrompt
        XCTAssertTrue(prompt.contains("API Developer")); XCTAssertTrue(prompt.contains(context.profileGuidance))
        XCTAssertTrue(prompt.contains("Do not claim to have inspected a repository"))
        XCTAssertFalse(prompt.contains("Act as an executive assistant."))
        XCTAssertTrue(prompt.contains("explicitly connected sources and the currently available tool set"))
        XCTAssertTrue(AssistantProfileKind.developer.planQuestion.contains("daily brief"))
        XCTAssertTrue(AssistantProfileKind.developer.starters[0].question.contains("relevant code"))
    }

    func testBackupRestoresCustomProfilesAndKeepsSelectionAndCurrentEditsOnRepeat() throws {
        var source = AppSnapshot()
        var context = ExecutiveProfile(); context.name = "Mira"; context.objectives = "Ship API"
        let custom = AssistantProfile(kind: .developer, title: "API work", context: context, additionalGuidance: "Use Swift examples")
        try source.profileLibrary.add(custom)
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(source))
        XCTAssertEqual(preview.profilesCount, 3)
        let (first, report) = WorkspaceBackup.merging(preview, into: AppSnapshot())
        XCTAssertEqual(report.profilesRestored, 1); XCTAssertEqual(first.profileLibrary.activeID, custom.id)
        XCTAssertEqual(first.profile.objectives, "Ship API")
        var edited = first
        var newer = edited.profileLibrary.active; newer.additionalGuidance = "My current guidance"; try edited.profileLibrary.update(newer)
        let (repeated, _) = WorkspaceBackup.merging(preview, into: edited)
        XCTAssertEqual(repeated.profileLibrary.profiles.count, 3)
        XCTAssertEqual(repeated.profileLibrary.active.additionalGuidance, "My current guidance")
    }

    func testSchemaFourBackupStillRestoresLegacyProfile() throws {
        let valid = try WorkspaceBackup.encode(AppSnapshot())
        var envelope = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        let compressed = Data(base64Encoded: envelope["payload"] as! String)!
        let bytes = try (compressed as NSData).decompressed(using: .lzfse) as Data
        var payload = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        payload["schemaVersion"] = 4; payload.removeValue(forKey: "profileLibrary")
        payload.removeValue(forKey: "developmentSessions")
        var legacy = ExecutiveProfile(); legacy.name = "Legacy user"; legacy.role = "CFO"; legacy.configured = true
        payload["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        envelope["payload"] = legacyData.base64EncodedString()
        envelope["version"] = 1; envelope.removeValue(forKey: "compression"); envelope.removeValue(forKey: "uncompressedBytes")
        envelope["sha256"] = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        let preview = try WorkspaceBackup.inspect(JSONSerialization.data(withJSONObject: envelope))
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot()).0
        XCTAssertEqual(restored.profile.name, legacy.name); XCTAssertEqual(restored.profile.role, legacy.role)
    }

    func testChatProfileLabelsAreOptionalForLegacyHistoryAndRoundTripNewReplies() throws {
        let old = ChatLine(role: "assistant", content: "Old reply")
        var new = ChatLine(role: "assistant", content: "Developer reply"); new.profileName = "Developer"
        XCTAssertNil(try JSONDecoder().decode(ChatLine.self, from: JSONEncoder().encode(old)).profileName)
        XCTAssertEqual(try JSONDecoder().decode(ChatLine.self, from: JSONEncoder().encode(new)).profileName, "Developer")
    }
}
