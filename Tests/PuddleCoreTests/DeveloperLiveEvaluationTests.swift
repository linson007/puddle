import Foundation
import XCTest
@testable import PuddleCore

private actor DeveloperLiveReceipts {
    var read = false
    func recordRead() { read = true }
}

final class DeveloperLiveEvaluationTests: XCTestCase {
    func testLocalModelReadsSyntheticProjectBeforeAnsweringWithSource() async throws {
        guard ProcessInfo.processInfo.environment["PUDDLE_LIVE_SPLASH"] == "1" else { throw XCTSkip("Optional real local-model evaluation") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-live-project-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let label = "puddle-check-" + UUID().uuidString.prefix(8)
        try Data("// Synthetic fixture only\nlet buildLabel = \"\(label)\"\n".utf8).write(to: root.appendingPathComponent("Main.swift"))
        let project = DeveloperProject(name: "Synthetic evaluation", path: root.path), receipts = DeveloperLiveReceipts()
        let splash = try SplashClient(address: "http://127.0.0.1:8000")
        let model = try await splash.modelInfo()
        var context = AgentContext(memoryLearning: false); context.profileKind = .developer
        context.profileName = "Developer"; context.developerProjectName = project.name
        let answer = try await LocalAgent(splash: splash).respond(
            question: "Use read_project_file to inspect Main.swift. What is the exact value of buildLabel? Cite Main.swift and its source line. Do not answer without reading the file.",
            history: [], context: context, tools: [.projectRead], execute: { call in
                let parameters = try call.parameters()
                guard call.function.name == AgentTool.projectRead.rawValue,
                      let path = parameters["path"] as? String, let line = parameters["start_line"] as? Int else { throw PuddleError("Invalid source request") }
                let result = try await ProjectInspection.run(.read(path, line), project: project)
                await receipts.recordRead(); return result.text
            }, model: model.id, contextTokens: min(8192, model.contextTokens ?? 8192))
        let read = await receipts.read
        XCTAssertTrue(read, "The model must inspect the file")
        XCTAssertTrue(answer.contains(label), "Answer must contain the random value that appears only in source")
        XCTAssertTrue(answer.contains("Main.swift"), "Answer must identify its source")
    }
}
