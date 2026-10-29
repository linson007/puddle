import AppKit
import Foundation
import PuddleCore

@MainActor protocol MeetBrowserLaunching: AnyObject {
    func connect() async throws -> any ChromeCommanding
}

@MainActor final class ManagedMeetBrowser: MeetBrowserLaunching {
    let directory: URL
    private var process: Process?
    private let transport: any HTTPTransport
    init(directory: URL, transport: any HTTPTransport = URLSessionTransport()) { self.directory = directory; self.transport = transport }

    func connect() async throws -> any ChromeCommanding {
        try Task.checkCancellation()
        try prepareDirectory()
        if let endpoint = try? await existingEndpoint() { return try ChromeDevTools(endpoint: endpoint) }
        if let process, process.isRunning { throw PuddleError("The dedicated Meet browser is still running but is not responding. Close its window before retrying.") }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let executable = Bundle(url: app)?.executableURL else {
            throw PuddleError("Install Google Chrome to use the local Meet attendance assistant. Other meeting features work without Chrome.")
        }
        let portFile = directory.appendingPathComponent("DevToolsActivePort")
        if FileManager.default.fileExists(atPath: portFile.path) { try FileManager.default.removeItem(at: portFile) }
        try preparePreferences()
        let process = Process(); process.executableURL = executable
        process.arguments = Self.arguments(directory: directory)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process
        for _ in 0..<80 {
            try Task.checkCancellation()
            if let endpoint = try? await existingEndpoint() { return try ChromeDevTools(endpoint: endpoint) }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PuddleError("Puddle's Meet browser did not become ready. Close its dedicated Chrome window and retry. Your usual Chrome profile is separate.")
    }
    static func arguments(directory: URL) -> [String] {
        ["--user-data-dir=\(directory.path)", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
         "--no-first-run", "--no-default-browser-check", "--lang=en-US", "--new-window", "about:blank"]
    }
    private func prepareDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PuddleError("The dedicated Meet browser directory is unavailable.") }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func preparePreferences() throws {
        let profile = directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = profile.appendingPathComponent("Preferences")
        // Never rewrite a live Chrome profile's preferences. Per-origin CDP
        // permissions are also denied before every managed Meet navigation.
        if FileManager.default.fileExists(atPath: file.path) { return }
        var preferences: [String: Any] = [:]
        var profileSettings = preferences["profile"] as? [String: Any] ?? [:]
        var permissions = profileSettings["default_content_setting_values"] as? [String: Any] ?? [:]
        permissions["media_stream_mic"] = 2; permissions["media_stream_camera"] = 2
        profileSettings["default_content_setting_values"] = permissions; preferences["profile"] = profileSettings
        var session = preferences["session"] as? [String: Any] ?? [:]; session["restore_on_startup"] = 5; preferences["session"] = session
        try ChromeJSON.data(preferences).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func existingEndpoint() async throws -> URL {
        let file = directory.appendingPathComponent("DevToolsActivePort")
        guard let bytes = try? Data(contentsOf: file), bytes.count <= 1024 else { throw PuddleError("The dedicated browser is starting.") }
        let endpoint = try ChromeJSON.endpoint(portFile: String(decoding: bytes, as: UTF8.self))
        var components = URLComponents(); components.scheme = "http"; components.host = "127.0.0.1"; components.port = endpoint.port; components.path = "/json/version"
        let (data, response) = try await transport.send(URLRequest(url: components.url!, timeoutInterval: 0.25))
        let object = try ChromeJSON.object(data)
        guard response.statusCode == 200, object["webSocketDebuggerUrl"] as? String == endpoint.absoluteString else {
            throw PuddleError("The dedicated browser endpoint changed. Close its window and retry.")
        }
        return endpoint
    }
}
