import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import PuddleCore

private final class BoundarySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) { lock.withLock { values[key] = data } }
    func delete(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private actor BoundaryHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let response: @Sendable (URLRequest) throws -> Data
    init(_ response: @escaping @Sendable (URLRequest) throws -> Data) { self.response = response }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (try response(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class IssueBoundaryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("issue-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func sparse(_ file: URL, bytes: Int) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }
    func testBoundedFileRejectsOversizeSymlinksDirectoriesAndFIFOs() throws {
        let root = try folder(), file = root.appendingPathComponent("large")
        try sparse(file, bytes: 2 * 1024 * 1024 * 1024)
        XCTAssertThrowsError(try BoundedFile.read(file, maximumBytes: 64))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedFile.read(link))
        XCTAssertThrowsError(try BoundedFile.read(root))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try BoundedFile.read(fifo))
        let ordinary = root.appendingPathComponent("ordinary")
        try Data("normal".utf8).write(to: ordinary)
        XCTAssertEqual(try BoundedFile.read(ordinary, maximumBytes: 6), Data("normal".utf8))
    }
    func testOversizedPrimaryRecoversBoundedBackupAndPreservesOriginal() throws {
        let root = try folder(), secrets = BoundarySecrets(), store = EncryptedSnapshotStore(directory: root, secrets: secrets)
        var state = AppSnapshot(); state.tasks = [AssistantTask(title: "Retained")]
        try store.save(state); try store.save(state)
        let primary = root.appendingPathComponent("workspace.vault")
        try FileManager.default.removeItem(at: primary); try sparse(primary, bytes: 2 * 1024 * 1024 * 1024)
        let result = try store.loadResult()
        XCTAssertEqual(result.snapshot.tasks.first?.title, "Retained"); XCTAssertNotNil(result.notice)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("workspace-unreadable-") }
        XCTAssertEqual(try TranscriptVault.fingerprint(XCTUnwrap(preserved)).bytes, 2 * 1024 * 1024 * 1024)
    }
    func testNonregularGenerationsDoNotFollowTargetsOrWedgeSaves() throws {
        for primary in [false, true] {
            let root = try folder(), secrets = BoundarySecrets(), store = EncryptedSnapshotStore(directory: root, secrets: secrets)
            var state = AppSnapshot(); state.tasks = [AssistantTask(title: "Original")]
            try store.save(state); try store.save(state)
            let path = root.appendingPathComponent(primary ? "workspace.vault" : "workspace.backup.vault")
            try FileManager.default.removeItem(at: path)
            let target = root.appendingPathComponent("untouched")
            try Data("outside".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            state.tasks[0].title = "Updated"
            if primary {
                XCTAssertThrowsError(try store.save(state))
                XCTAssertThrowsError(try store.save(state), "A failed save cannot authorize a stale retry")
                state = try store.load(); state.tasks[0].title = "Updated"
            }
            try store.save(state)
            XCTAssertEqual(try store.load().tasks.first?.title, "Updated")
            XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
        }
    }
    func testNeverLoadedStoreCannotRecoverThenOverwriteNonregularPrimary() throws {
        let root = try folder(), secrets = BoundarySecrets(), original = EncryptedSnapshotStore(directory: root, secrets: secrets)
        var state = AppSnapshot(); state.tasks = [AssistantTask(title: "Retain acknowledged work")]
        try original.save(state); try original.save(state)
        let file = root.appendingPathComponent("workspace.vault")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let fresh = EncryptedSnapshotStore(directory: root, secrets: secrets)
        XCTAssertThrowsError(try fresh.save(AppSnapshot()))
        XCTAssertEqual(try fresh.load().tasks, state.tasks)
    }
    func testAbandonedWritesArePrunedButFreshAndUnknownFilesRemain() throws {
        let root = try folder(), store = EncryptedSnapshotStore(directory: root, secrets: BoundarySecrets())
        let old = root.appendingPathComponent(".backup-\(UUID()).vault"), fresh = root.appendingPathComponent(".backup-\(UUID()).vault")
        let temporary = root.appendingPathComponent(".puddle-write-\(UUID())"), unknown = root.appendingPathComponent(".backup-unknown.vault")
        for url in [old, fresh, temporary, unknown] { try Data("orphan".utf8).write(to: url) }
        for url in [old, temporary, unknown] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: url.path) }
        try store.save(AppSnapshot())
        XCTAssertFalse(BoundedFile.exists(old)); XCTAssertFalse(BoundedFile.exists(temporary))
        XCTAssertTrue(BoundedFile.exists(fresh)); XCTAssertTrue(BoundedFile.exists(unknown))
    }
    func testCredentialFilenamesAndBareValuesAreWithheld() {
        for path in [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd", ".docker/config.json", ".docker-prod/config.json", ".kube/config.yaml", "id_dsa", "id_ecdsa", ".dockercfg"] {
            XCTAssertFalse(ProjectFiles.permits(path), path)
        }
        for content in ["password = barevalue123", "password barevalue123", "_authToken=fixturetoken123", #"{"password":"barevalue123"}"#, "api_key: barevalue123"] {
            XCTAssertTrue(ProjectFiles.containsCredential(content), content)
        }
        XCTAssertFalse(ProjectFiles.containsCredential("let token = \"short\""))
        XCTAssertTrue(ProjectFiles.permits("Sources/Feature.swift"))
    }
    func testDeepJSONIsRejectedBeforeRecursiveDecodeAndQuotedBracketsWork() throws {
        let deep = Data((String(repeating: "[", count: 100_000) + "0" + String(repeating: "]", count: 100_000)).utf8)
        XCTAssertThrowsError(try WorkConnectorHTTP.decode(deep))
        XCTAssertThrowsError(try AgentToolCall(name: "read", arguments: String(decoding: deep, as: UTF8.self)).parameters())
        let quoted = ConnectorJSON.object(["text": .string(String(repeating: "[\\\"]", count: 200))]).data
        XCTAssertNoThrow(try WorkConnectorHTTP.decode(quoted))
        let ordinary = Data((String(repeating: "[", count: 12) + "0" + String(repeating: "]", count: 12)).utf8)
        XCTAssertNoThrow(try WorkConnectorHTTP.decode(ordinary))
        let boundary = Data((String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64)).utf8)
        XCTAssertNoThrow(try WorkConnectorHTTP.decode(boundary))
    }
    func testCallbackPinsHostPortPathAndRejectsUserinfoFragmentsAndErrors() throws {
        let flow = OAuthFlow(verifier: "fixture", state: "correct"), redirect = URL(string: "http://127.0.0.1:4321/")!
        for base in ["http://attacker.example:4321/", "https://127.0.0.1:4321/", "http://localhost:4321/", "http://127.0.0.1:4322/", "http://127.0.0.1:4321/other", "http://user@127.0.0.1:4321/"] {
            XCTAssertThrowsError(try flow.code(from: URL(string: base + "?state=correct&code=fixture")!, redirect: redirect), base)
        }
        for suffix in ["#fragment", "&error&error=denied"] {
            XCTAssertThrowsError(try flow.code(from: URL(string: redirect.absoluteString + "?state=correct&code=fixture" + suffix)!, redirect: redirect))
        }
        XCTAssertEqual(try flow.code(from: URL(string: redirect.absoluteString + "?state=correct&code=fixture")!, redirect: redirect), "fixture")
    }
    func testDriverEnvironmentDropsSecretsAndPreservesRequiredRuntimeValues() {
        let value = CuaStdioTransport.childEnvironment(["OPENAI_API_KEY": "private", "GITHUB_TOKEN": "private", "AWS_SESSION_TOKEN": "private", "DYLD_INSERT_LIBRARIES": "bad", "CUA_DRIVER_PERMISSION_MODE": "unsafe", "HOME": "/fixture", "PATH": "/usr/bin", "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "TMPDIR": "/tmp"])
        XCTAssertEqual(Set(value.keys), ["HOME", "PATH", "LANG", "LC_CTYPE", "TMPDIR", "CUA_DRIVER_PERMISSION_MODE"])
        XCTAssertEqual(value["CUA_DRIVER_PERMISSION_MODE"], "standard")
    }
    func testSensitiveMemoryFormatsAndImpersonalNamesAreRejected() {
        for value in ["4111 1111 1111 1111", "123-45-6789", "eyJhbGciOiJub25l.eyJzdWIiOiIxIn0.signature", "xoxb-fixture123456", "AKIAABCDEFGHIJKLMNOP", "AIzaFixtureKey12345678901234567890", "sk_live_fixture123456", "token: fixture123456", "routing: 123456789", "My routing number is 123456789", "My bank account number is 1234567890"] {
            let message = "My preference is " + value
            XCTAssertTrue(MemoryLearning.containsSensitiveData(message), value)
            XCTAssertThrowsError(try MemoryUpdate.validated(title: "Preference", content: value, source: message, userMessage: message))
        }
        XCTAssertFalse(MemoryLearning.containsSensitiveData("I work on a project launched in 2026 and prefer concise replies"))
        for value in ["call me the boss", "call me your guardian angel", "my name is my own business"] { XCTAssertNil(NameMemoryProposal.from(value)) }
        XCTAssertEqual(NameMemoryProposal.from("call me Priya")?.name, "Priya")
    }
    func testPassiveAndAttachmentDraftClaimsNeedTrustedSupport() throws {
        for claim in ["Please find attached", "the file is attached", "it's all set", "enclosed is the report", "it has been sent", "I spoke with them", "attached herewith", "I have gone ahead and approved the invoice."] {
            XCTAssertThrowsError(try DraftGrounding.validate(claim, userContext: "Ask for an update."), claim)
        }
        XCTAssertThrowsError(try DraftGrounding.validate("The file is attached.", userContext: "Do not say the file is attached."))
        XCTAssertNoThrow(try DraftGrounding.validate("Please find attached", userContext: "I attached the report."))
        XCTAssertNoThrow(try DraftGrounding.validate("I have spoken with them", userContext: "I spoke with them."))
    }
    func testTransitionAndReservedIPv6AreRejectedInEquivalentSpellings() {
        for address in ["2002:0a00:0001::", "3fff::1", "3fff:f00::1", "2001:0000:4136:e378:8000:63bf:f5ff:fffe", "2001:10::1", "2001:20::1", "2001:2::1", "2001:0db8::1", "2001:db8:0:0:0:0:0:1", "64:ff9b::a00:1", "::ffff:10.0.0.1"] { XCTAssertFalse(PublicNewsletterHost.isPublic(address), address) }
        XCTAssertTrue(PublicNewsletterHost.isPublic("2606:4700:4700::1111"))
        XCTAssertTrue(PublicNewsletterHost.isPublic("8.8.8.8"))
    }
    func testMeetingSearchCapsLargeLibraryAndReportsMore() throws {
        let notes = (0..<5000).map { MeetingNote(title: "Launch \($0)") }
        let page = try MeetingSearch.page(notes: notes, query: "launch")
        XCTAssertEqual(page.results.count, 80); XCTAssertTrue(page.hasMore)
        XCTAssertFalse(try MeetingSearch.page(notes: Array(notes.prefix(80)), query: "launch").hasMore)
    }
    func testCalendarListFollowsPagesAndRejectsRepeatedContinuation() async throws {
        let secrets = BoundarySecrets()
        secrets.write(try JSONEncoder().encode(GoogleCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, scope: OAuthFlow.calendarScope)), key: "google-tokens")
        let http = BoundaryHTTP { request in
            let hasPage = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "pageToken" && $0.value == "next" } == true
            return Data((hasPage ? #"{"items":[{"id":"second"}]}"# : #"{"items":[{"id":"first"}],"nextPageToken":"next"}"#).utf8)
        }
        let calendars = try await GoogleCalendarClient(session: GoogleSession(store: secrets), transport: http).calendars()
        XCTAssertEqual(calendars.map(\.id), ["first", "second"])
        let repeated = BoundaryHTTP { _ in Data(#"{"items":[],"nextPageToken":"same"}"#.utf8) }
        do { _ = try await GoogleCalendarClient(session: GoogleSession(store: secrets), transport: repeated).calendars(); XCTFail("Repeated page accepted") } catch {}
    }
    func testCancelledKnowledgeSearchAndBackgroundWorkDoNotPublish() async throws {
        let doc = KnowledgeDocument(sourceID: UUID(), name: "Fixture", url: URL(fileURLWithPath: "/fixture"), modifiedAt: Date(), bytes: 200_000, text: String(repeating: "line\n", count: 40_000), limited: false)
        let task = Task { try await LocalKnowledge.searchAsync("absent", documents: Array(repeating: doc, count: 100)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search returned") } catch is CancellationError {}
        let matches = try await LocalKnowledge.searchAsync("line", documents: [doc])
        XCTAssertEqual(matches.count, 20)
    }
    func testOversizedOAuthResponseIsRejectedBeforeTokenParsing() async throws {
        let secrets = BoundarySecrets()
        secrets.write(try JSONEncoder().encode(GoogleClientConfiguration(clientID: "fixture.apps.googleusercontent.com")), key: "google-client")
        secrets.write(try JSONEncoder().encode(GoogleCredentials(accessToken: "expired", refreshToken: "fixture", expiresAt: .distantPast, scope: OAuthFlow.scope)), key: "google-tokens")
        let http = BoundaryHTTP { _ in Data(repeating: 65, count: 256 * 1024 + 1) }
        do { _ = try await GoogleSession(store: secrets, transport: http).accessToken(); XCTFail("Oversized OAuth body accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("size limit"), error.localizedDescription) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }
    private func envelope(_ content: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: content)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: ["format": "puddle-workspace", "version": 1, "createdAt": 0, "payload": payload.base64EncodedString(), "sha256": digest])
    }
    private func backupContent() throws -> [String: Any] {
        let data = try WorkspaceBackup.encode(AppSnapshot())
        let outer = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = try XCTUnwrap(Data(base64Encoded: outer["payload"] as! String))
        return try JSONSerialization.jsonObject(with: (payload as NSData).decompressed(using: .lzfse) as Data) as! [String: Any]
    }
    func testBackupInspectRejectsEachOversizedCollectionBeforeMerge() throws {
        let cases: [(String, Int, (Int) throws -> Any)] = [
            ("memories", WorkspaceBackup.maximumMemories, { try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemoryNote(title: "Memory \($0)", content: "Saved"))) }),
            ("tasks", WorkspaceBackup.maximumTasks, { _ in try JSONSerialization.jsonObject(with: JSONEncoder().encode(AssistantTask(title: "Saved"))) }),
            ("meetings", WorkspaceBackup.maximumMeetings, { _ in try JSONSerialization.jsonObject(with: JSONEncoder().encode(MeetingNote(title: "Saved"))) }),
            ("conversations", WorkspaceBackup.maximumConversations, { _ in try JSONSerialization.jsonObject(with: JSONEncoder().encode(Conversation(lines: []))) }),
            ("browserErrands", WorkspaceBackup.maximumErrands, { _ in try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserErrand(goal: "Saved"))) }),
        ]
        for (name, limit, make) in cases {
            var content = try backupContent()
            content[name] = try (0...limit).map(make)
            XCTAssertThrowsError(try WorkspaceBackup.inspect(envelope(content)), name)
        }
    }
    func testBackupChatContentAndReceiptsAreBoundedAndEncodeIsConsistent() throws {
        var content = try backupContent()
        var line = ChatLine(role: "assistant", content: String(repeating: "x", count: 1024 * 1024 + 1))
        content["conversations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Conversation(lines: [line])]))
        XCTAssertThrowsError(try WorkspaceBackup.inspect(envelope(content)))
        line.content = "Ordinary reply"; line.receipts = [ToolReceipt(id: "fixture", tool: "read", detail: String(repeating: "x", count: 4001))]
        content["conversations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Conversation(lines: [line])]))
        XCTAssertThrowsError(try WorkspaceBackup.inspect(envelope(content)))
        var state = AppSnapshot(); state.chat = [line]
        XCTAssertThrowsError(try WorkspaceBackup.encode(state))
        line.receipts = nil; state.chat = [line]
        XCTAssertNoThrow(try WorkspaceBackup.inspect(WorkspaceBackup.encode(state)))
    }
    func testBackupMergeHonorsCombinedCollectionLimits() throws {
        var source = AppSnapshot()
        source.memories = [MemoryNote(title: "Imported", content: "Saved")]
        source.tasks = [AssistantTask(title: "Imported")]; source.meetings = [MeetingNote(title: "Imported")]
        source.conversations = [Conversation(lines: [ChatLine(role: "user", content: "Imported")])]
        source.browserErrands = [BrowserErrand(goal: "Imported")]
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(source))
        var current = AppSnapshot()
        current.memories = (0..<WorkspaceBackup.maximumMemories).map { MemoryNote(title: "Current \($0)", content: "Saved") }
        current.tasks = (0..<WorkspaceBackup.maximumTasks).map { _ in AssistantTask(title: "Current") }
        current.meetings = (0..<WorkspaceBackup.maximumMeetings).map { _ in MeetingNote(title: "Current") }
        current.conversations = (0..<WorkspaceBackup.maximumConversations).map { _ in Conversation(lines: [ChatLine(role: "user", content: "Current")]) }
        current.browserErrands = (0..<WorkspaceBackup.maximumErrands).map { _ in BrowserErrand(goal: "Current") }
        let (merged, report) = WorkspaceBackup.merging(preview, into: current)
        XCTAssertEqual(merged.memories.count, current.memories.count); XCTAssertEqual(merged.tasks.count, current.tasks.count)
        XCTAssertEqual(merged.meetings.count, current.meetings.count); XCTAssertEqual(merged.conversations.count, current.conversations.count)
        XCTAssertEqual(merged.browserErrands.count, current.browserErrands.count)
        XCTAssertEqual(report.skipped, 5)
    }
}
