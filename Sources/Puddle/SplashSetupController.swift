import AppKit
import Combine
import PuddleCore

@MainActor final class SplashSetupController: ObservableObject {
    @Published private(set) var hardware: LocalAIHardware?
    @Published var executable: String
    @Published private(set) var brew: String?
    @Published private(set) var status = ""
    @Published private(set) var output = ""
    @Published private(set) var isInstalling = false
    @Published private(set) var ownsServer = false
    @Published private(set) var isVerifying = false
    @Published private(set) var verification: SplashSetupVerification?
    @Published private(set) var error: String?
    private var process: Process?
    private var pipe: Pipe?
    private var operation: Task<Void, Never>?
    private var revision = UUID()
    private let preferences: UserDefaults
    init(hardware: LocalAIHardware? = nil, preferences: UserDefaults = .standard) {
        self.hardware = hardware; self.preferences = preferences
        executable = preferences.string(forKey: "splashExecutable") ?? ""
    }

    func inspect() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var chip = "Unknown Mac", count = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &count, nil, 0)
        if count > 0 {
            var bytes = [CChar](repeating: 0, count: count)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &count, nil, 0) == 0 { chip = String(cString: bytes) }
        }
        let disk = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value
        hardware = LocalAIHardware(chip: chip, memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: disk, os: os)
        let search = ["/opt/homebrew/bin/splash", "/usr/local/bin/splash", NSHomeDirectory() + "/.local/bin/splash"]
        if !FileManager.default.isExecutableFile(atPath: executable) { executable = search.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "" }
        brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose your installed splash executable, including a source checkout’s splash launcher."
        if panel.runModal() == .OK, let path = panel.url?.path {
            executable = path; preferences.set(path, forKey: "splashExecutable")
        }
    }
    func install() {
        guard let brew, process == nil else { return }
        launch(executable: brew, arguments: ["install", "incoai/tap/splash"], installing: true)
    }
    func start(preset: SplashModelPreset, port: Int, offline: Bool = false) {
        guard process == nil, let hardware else { return }
        let issues = hardware.issues(for: preset)
        guard issues.isEmpty else { error = issues.joined(separator: "\n"); return }
        do { launch(executable: executable, arguments: try preset.arguments(port: port, offline: offline), installing: false) }
        catch { self.error = error.localizedDescription }
    }
    private func launch(executable: String, arguments: [String], installing: Bool) {
        guard FileManager.default.isExecutableFile(atPath: executable), process == nil else { error = "Choose an installed executable and finish the current operation first."; return }
        invalidateVerification(); error = nil; output = ""
        let child = Process(), pipe = Pipe(), expected = UUID(); revision = expected
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"; environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.revision == expected else { return }
                self.output = String((self.output + text).suffix(24_000))
            }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.revision == expected else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil; self.pipe = nil; self.isInstalling = false; self.ownsServer = false
                self.status = terminated.terminationStatus == 0 ? (installing ? "Splash installed. Choose a model and start it." : "Splash stopped.") : "Process stopped (code \(terminated.terminationStatus)). Review the setup log and retry."
                self.inspect()
            }
        }
        do {
            try child.run(); self.process = child; self.pipe = pipe
            isInstalling = installing; ownsServer = !installing
            status = installing ? "Installing Splash with Homebrew…" : "Starting Splash. The first run downloads model weights; this can take several minutes."
            if !installing { preferences.set(executable, forKey: "splashExecutable") }
        } catch { pipe.fileHandleForReading.readabilityHandler = nil; self.error = "Could not start: \(error.localizedDescription)" }
    }
    func verify(client: SplashClient) {
        guard !isVerifying else { return }
        let expected = UUID(); revisionForVerification = expected
        isVerifying = true; verification = nil; error = nil
        operation = Task {
            do {
                let result = try await client.verifySetup()
                guard !Task.isCancelled, revisionForVerification == expected else { return }
                verification = result; isVerifying = false
                status = result.toolCalling ? "Local reply and tool calling verified." : "Local replies work. Tool calling did not pass; try another compatible model before using assistant actions."
            } catch {
                guard revisionForVerification == expected else { return }
                isVerifying = false
                if !(error is CancellationError) { self.error = error.localizedDescription + " Check that the model is ready, the port matches, and any API key is correct. Review the setup log for download, disk, or memory errors." }
            }
        }
    }
    private var revisionForVerification = UUID()
    func invalidateVerification() { revisionForVerification = UUID(); operation?.cancel(); operation = nil; verification = nil; isVerifying = false }
    func stop() {
        invalidateVerification()
        if let process, process.isRunning { process.terminate(); status = "Stopping the process Puddle started…" }
    }
}
