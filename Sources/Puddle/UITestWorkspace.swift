#if DEBUG
import AppKit
import CryptoKit
import Foundation
import PuddleCore

/// Explicit debug-only native acceptance workspace. Never reads personal credentials.
enum UITestWorkspace {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-workspace") || Bundle.main.object(forInfoDictionaryKey: "PuddleUITestWorkspace") != nil
    }
    static func launchArguments(_ arguments: [String], bundledWorkspace: Any?) throws -> [String] {
        if arguments.contains("--ui-test-workspace") || bundledWorkspace == nil { return arguments }
        guard let path = bundledWorkspace as? String, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              URL(fileURLWithPath: path).standardizedFileURL.path != "/" else {
            throw PuddleError("The acceptance app needs an absolute disposable workspace path. Refusing to open personal state.")
        }
        return arguments + ["--ui-test-workspace", path, "--ui-test-empty"]
    }
    static func recordAudioDiagnostic(_ message: String) {
        guard enabled else { return }
        let supplied = ProcessInfo.processInfo.arguments
        let path: String?
        if let index = supplied.firstIndex(of: "--ui-test-workspace"), supplied.indices.contains(index + 1) { path = supplied[index + 1] }
        else { path = Bundle.main.object(forInfoDictionaryKey: "PuddleUITestWorkspace") as? String }
        guard let path else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent("audio-diagnostics.log")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1_048_576 else { return }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data((String(message.prefix(2000)) + "\n").utf8))
        } catch { /* Fixture diagnostics must not interrupt capture. */ }
    }
    @MainActor static func makeStore(arguments suppliedArguments: [String] = ProcessInfo.processInfo.arguments,
                                     bundledWorkspace: Any? = Bundle.main.object(forInfoDictionaryKey: "PuddleUITestWorkspace")) -> PuddleStore {
        let arguments: [String]
        do { arguments = try launchArguments(suppliedArguments, bundledWorkspace: bundledWorkspace) }
        catch { fatalError(error.localizedDescription) }
        guard let index = arguments.firstIndex(of: "--ui-test-workspace"), arguments.indices.contains(index + 1) else { fatalError("Supply a disposable UI test directory.") }
        if arguments.contains("--ui-test-dark-appearance") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        let secrets = UITestSecrets(directory: directory)
        let empty = arguments.contains("--ui-test-empty")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !empty {
                let scopes = [OAuthFlow.scope, OAuthFlow.mailSendScope, OAuthFlow.mailModifyScope, OAuthFlow.calendarScope, OAuthFlow.calendarWriteScope, OAuthFlow.calendarListScope].joined(separator: " ")
                let credentials = try ["one", "two"].map { id in
                    let account = try JSONDecoder().decode(GoogleAccount.self, from: JSONSerialization.data(withJSONObject: ["id": id, "email": id + "@puddle.test", "name": "UI Fixture " + id]))
                    return GoogleCredentials(accessToken: "ui-fixture-" + id, refreshToken: "fixture", expiresAt: Date().addingTimeInterval(86400), scope: scopes, account: account)
                }
                if try secrets.read("google-tokens") == nil { try secrets.write(JSONEncoder().encode(credentials[0]), key: "google-tokens") }
                try secrets.write(JSONEncoder().encode(credentials), key: "google-accounts")
                try secrets.write(JSONEncoder().encode(GoogleClientConfiguration(clientID: "fixture.apps.googleusercontent.com")), key: "google-client")
                try secrets.write(JSONEncoder().encode(MicrosoftClientConfiguration(clientID: "11111111-2222-3333-4444-555555555555")), key: "microsoft-client")
                if try secrets.read("microsoft-accounts") == nil {
                    let accounts: [[String: Any]] = ["one", "two"].map { id in
                        ["account": ["id": id, "email": id + "@outlook.puddle.test", "scopes": ["User.Read", "Mail.Read", "Mail.Send", "Mail.ReadWrite"]], "accessToken": "ui-outlook-" + id, "refreshToken": "fixture", "expiresAt": Date().addingTimeInterval(86400).timeIntervalSinceReferenceDate]
                    }
                    try secrets.write(JSONSerialization.data(withJSONObject: ["accounts": accounts, "activeID": "one"]), key: "microsoft-accounts")
                }
            }
            let cache = EncryptedSnapshotStore(directory: directory, secrets: secrets)
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace.vault").path) {
                var state = AppSnapshot(); state.settings.automaticallyLearn = false; state.settings.notifications = false
                if let seed = arguments.firstIndex(of: "--ui-test-seed"), arguments.indices.contains(seed + 1) {
                    let url = URL(fileURLWithPath: arguments[seed + 1])
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 120 * 1024 * 1024 else { throw PuddleError("Choose a regular synthetic seed under 120 MB.") }
                    state = try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: url))
                    state.settings.automaticallyCheck = false; state.settings.automaticallyLearn = false; state.settings.notifications = false
                }
                state.profile.configured = !empty
                if empty { state.settings.splashAddress = "http://127.0.0.1:65534"; state.settings.automaticallyCheck = false }
                try cache.save(state)
            }
            return PuddleStore(directory: directory, cache: cache, secrets: secrets, transport: UITestHTTP(directory: directory), reminderScheduler: UITestReminderScheduler())
        } catch { fatalError("The isolated UI test workspace could not start: \(error)") }
    }
}

/// A synthetic workspace must never reconcile real macOS notification requests.
@MainActor private final class UITestReminderScheduler: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}

/// Contains synthetic fixture credentials only. Ad hoc rebuilds cannot block on Keychain ACL prompts.
private final class UITestSecrets: SecretStore, @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    init(directory: URL) { file = directory.appendingPathComponent("fixture-secrets.json") }
    private func values() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? 0) < 1_048_576 else { throw PuddleError("Invalid synthetic UI credential file.") }
        return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
    }
    func read(_ key: String) throws -> Data? { try lock.withLock { try values()[key] } }
    func write(_ data: Data, key: String) throws { try lock.withLock {
        var next = try values(); next[key] = data
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } }
    func delete(_ key: String) throws { try lock.withLock {
        var next = try values(); next.removeValue(forKey: key)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } }
}

actor UITestHTTP: HTTPTransport {
    private let real = URLSessionTransport()
    private let directory: URL
    private var events: [[String: Any]]
    private var labels: [String: [String]] = [:]
    private var sequence = 0
    init(directory: URL) {
        self.directory = directory
        let day = Calendar.current.startOfDay(for: Date())
        func event(_ id: String, _ title: String, _ hour: Int) -> [String: Any] {
            ["id": id, "summary": title, "start": ["dateTime": day.addingTimeInterval(Double(hour) * 3600).ISO8601Format()], "end": ["dateTime": day.addingTimeInterval(Double(hour) * 3600 + 1800).ISO8601Format()], "etag": "\"fixture-1\"", "attendees": [["email": "alex@puddle.test"]], "htmlLink": "https://calendar.google.com/calendar/event?eid=fixture", "recurringEventId": "weekly-planning"]
        }
        events = [event("planning", "UI test planning", 10), event("review", "UI test review", 14)]
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw PuddleError("Missing UI test URL") }
        if ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") { return try await real.send(request) }
        let host = url.host ?? "", path = url.path, method = request.httpMethod ?? "GET"
        let allowed = ["gmail.googleapis.com", "www.googleapis.com", "graph.microsoft.com", "news.puddle.test"]
        guard allowed.contains(host) else { throw PuddleError("UI fixture mode blocks external requests to \(host).") }
        let line = "\(method) \(host)\(path)\n"
        let log = directory.appendingPathComponent("provider-journal.txt")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
        var object: Any = [:], status = 200
        if host == "news.puddle.test" { status = 204 }
        else if host == "gmail.googleapis.com" {
            let parts = path.split(separator: "/"), last = parts.last.map(String.init) ?? ""
            if last == "profile" { object = ["emailAddress": request.value(forHTTPHeaderField: "Authorization")?.contains("two") == true ? "two@puddle.test" : "one@puddle.test", "historyId": "100"] }
            else if last == "history" { object = ["historyId": "100", "history": []] }
            else if last == "messages" { object = ["messages": ["planning-mail", "newsletter"].filter { (labels[$0] ?? ["INBOX"]).contains("INBOX") }.map { ["id": $0] }] }
            else if path.contains("/attachments/") { object = ["data": Data("UI test attachment. Launch review is Friday. Owner: Alex.".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")] }
            else if path.contains("/threads/") { object = ["messages": [message("planning-mail"), message("reply")]] }
            else if last == "send" { sequence += 1; object = ["id": "sent-\(sequence)", "threadId": "fixture-thread"] }
            else if last == "modify", parts.count > 1 {
                let id = String(parts[parts.count - 2]), input = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                var current = labels[id] ?? ["INBOX", "UNREAD", "IMPORTANT"]
                current.removeAll { (input["removeLabelIds"] as? [String] ?? []).contains($0) }
                current += (input["addLabelIds"] as? [String] ?? []).filter { !current.contains($0) }; labels[id] = current
                object = ["id": id, "threadId": "fixture-thread", "labelIds": current]
            } else { object = message(last) }
        } else if host == "www.googleapis.com", path.contains("/calendar/") {
            if path.hasSuffix("calendarList") { object = ["items": [["id": "primary", "summary": "Fixture primary", "accessRole": "owner"], ["id": "team", "summary": "Fixture team", "accessRole": "owner"]]] }
            else if method == "GET" { object = ["items": events] }
            else if method == "DELETE" { events.removeAll { ($0["id"] as? String) == url.lastPathComponent }; status = 204 }
            else {
                sequence += 1; var changed = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let id = method == "PATCH" ? url.lastPathComponent : changed["id"] as? String ?? "created-\(sequence)"
                changed["id"] = id; changed["etag"] = "\"fixture-\(sequence + 1)\""; changed["htmlLink"] = "https://calendar.google.com/calendar/event?eid=fixture"
                events.removeAll { ($0["id"] as? String) == id }; events.append(changed); object = changed
            }
        } else if host == "graph.microsoft.com" {
            if path.hasSuffix("sendMail") { status = 202 }
            else if method != "GET" { object = ["id": "outlook-fixture"] }
            else if path.contains("attachments") { object = ["value": []] }
            else {
                object = ["value": [["id": "outlook-message", "conversationId": "outlook-thread", "subject": "UI test Outlook planning", "from": ["emailAddress": ["address": "alex@puddle.test"]], "receivedDateTime": Date().ISO8601Format(), "isRead": false, "importance": "high", "body": ["contentType": "text", "content": "Synthetic Outlook message for end-to-end testing."], "webLink": "https://outlook.office.com/mail/fixture"]]]
            }
        } else { throw PuddleError("Unsupported UI fixture route: \(path)") }
        return (status == 204 || status == 202 ? Data() : try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        guard ["127.0.0.1", "localhost", "::1"].contains(request.url?.host ?? "") else { throw PuddleError("UI fixtures never stream from an external service.") }
        return try await real.stream(request, onLine: onLine)
    }
    private func message(_ id: String) -> [String: Any] {
        let newsletter = id == "newsletter"
        let headers = ["From": newsletter ? "Updates <news@puddle.test>" : "Alex <alex@puddle.test>", "To": "one@puddle.test", "Subject": newsletter ? "UI test newsletter" : "UI test launch planning", "Message-ID": "<\(id)@puddle.test>", "List-Unsubscribe": "<https://news.puddle.test/one-click>", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"].map { ["name": $0.key, "value": $0.value] }
        return ["id": id, "threadId": "fixture-thread", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": labels[id] ?? ["INBOX", "UNREAD", "IMPORTANT"], "snippet": "Synthetic planning note", "payload": ["mimeType": "multipart/mixed", "headers": headers, "parts": [["mimeType": "text/plain", "body": ["data": Data("Please review the launch plan. Alex owns the review by Friday.".utf8).base64EncodedString()]], ["mimeType": "text/plain", "filename": "launch-plan.txt", "body": ["attachmentId": "attachment", "size": 60]]]]]
    }
}
#endif
