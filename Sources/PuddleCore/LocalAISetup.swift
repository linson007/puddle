import Foundation

public struct LocalAIHardware: Sendable {
    public let chip: String
    public let memoryBytes: UInt64
    public let freeDiskBytes: Int64?
    public let os: OperatingSystemVersion
    public init(chip: String, memoryBytes: UInt64, freeDiskBytes: Int64?, os: OperatingSystemVersion) {
        self.chip = chip; self.memoryBytes = memoryBytes; self.freeDiskBytes = freeDiskBytes; self.os = os
    }
    public var memoryGB: Int { Int(memoryBytes / 1_073_741_824) }
    public var supportsSplash: Bool {
        let generations = chip.split(separator: " ").compactMap { word -> Int? in
            guard word.first == "M" else { return nil }; return Int(word.dropFirst())
        }
        return chip.contains("Apple") && generations.contains(where: { $0 >= 3 }) &&
            (os.majorVersion > 26 || (os.majorVersion == 26 && os.minorVersion >= 4))
    }
    public var recommendation: SplashModelPreset { memoryGB >= 32 ? .balanced : .compact }
    public func issues(for preset: SplashModelPreset) -> [String] {
        var issues: [String] = []
        if !supportsSplash { issues.append("The current Splash engine requires Apple M3 or newer and macOS 26.4 or later. You can still connect an already running compatible local server.") }
        if memoryGB < preset.minimumMemoryGB { issues.append("This preset needs at least \(preset.minimumMemoryGB) GB of unified memory. Choose a smaller preset or use an existing compatible model.") }
        if let freeDiskBytes, freeDiskBytes < Int64(preset.diskBudgetGB) * 1_073_741_824 {
            issues.append("Allow about \(preset.diskBudgetGB) GB of free disk space for the model, draft, and download headroom.")
        }
        return issues
    }
}

public enum SplashModelPreset: String, CaseIterable, Identifiable, Sendable {
    case compact, balanced
    public var id: String { rawValue }
    public var title: String { self == .compact ? "Compact · 24 GB Macs" : "Balanced · 32 GB+ Macs" }
    public var model: String {
        self == .compact ? "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS" : "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"
    }
    public var minimumMemoryGB: Int { self == .compact ? 24 : 32 }
    public var diskBudgetGB: Int { self == .compact ? 20 : 26 }
    public var detail: String {
        self == .compact ? "Lower memory use. Quality and speed depend on your Mac; verify chat and tools below." : "More headroom for quality. Leaves room for daily work on a 32 GB or larger Mac."
    }
    public func arguments(port: Int = 8000, offline: Bool = false) throws -> [String] {
        guard (1024...65535).contains(port) else { throw PuddleError("Choose a local port between 1024 and 65535.") }
        return ["serve", "--model", model, "--host", "127.0.0.1", "--port", String(port), "--max-context", "32768", "--language-only"] + (offline ? ["--offline"] : [])
    }
}

public struct SplashSetupVerification: Sendable {
    public let model: SplashModel
    public let answer: String
    public let toolCalling: Bool
    public let toolDiagnostic: String?
    public let checkedAt: Date
    public init(model: SplashModel, answer: String, toolCalling: Bool, checkedAt: Date = Date(), toolDiagnostic: String? = nil) {
        self.model = model; self.answer = answer; self.toolCalling = toolCalling; self.checkedAt = checkedAt; self.toolDiagnostic = toolDiagnostic
    }
}

extension SplashClient {
    /// Synthetic setup probes never retrieve personal data or execute an action.
    public func verifySetup() async throws -> SplashSetupVerification {
        let model = try await modelInfo()
        let answer = try await agentStep(messages: [AgentMessage(role: "user", content: "Say hello in one short sentence. This is a local connection test.")], tools: [], model: model.id, maxTokens: 100)
        guard !answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.calls.isEmpty,
              answer.finishReason != "length" else { throw PuddleError("The model connected but did not finish a simple reply. Check its configuration and retry.") }
        do {
            let probe = try await agentStep(messages: [AgentMessage(role: "user", content: "Call list_tasks exactly once with an empty object. Do not answer in prose.")], tools: [.tasks], model: model.id, requireToolCall: true, maxTokens: 150)
            let toolCalling = probe.finishReason != "length" && probe.calls.count == 1 && probe.calls[0].function.name == AgentTool.tasks.rawValue &&
                ((try? JSONSerialization.jsonObject(with: Data(probe.calls[0].function.arguments.utf8))) as? [String: Any])?.isEmpty == true
            try Task.checkCancellation()
            return SplashSetupVerification(model: model, answer: answer.content, toolCalling: toolCalling,
                toolDiagnostic: toolCalling ? nil : "Chat works. This model did not return the required tool call. Check its tool template or choose a tool-capable model.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return SplashSetupVerification(model: model, answer: answer.content, toolCalling: false, toolDiagnostic: "Chat works; the tool probe failed: \(String(error.localizedDescription.prefix(500)))")
        }
    }
}
