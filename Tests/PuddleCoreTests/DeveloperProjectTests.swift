import Darwin
import Foundation
import XCTest
@testable import PuddleCore

final class DeveloperProjectTests: XCTestCase {
    private func fixture() throws -> (URL, DeveloperProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-project-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, DeveloperProject(name: "Fixture", path: root.path))
    }
    private func write(_ text: String, _ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func testInventoryExcludesPrivateGeneratedBinaryAndSymbolicPathsAndCanRunTwice() throws {
        let (root, project) = try fixture()
        for path in ["Sources/Main.swift", "README.md", ".gitignore", "node_modules/lib.js", ".env", "nested/.env.local", "client_secret.json", "secrets.json", "key.pem", ".git/config", "build/generated.swift", "photo.png"] { try write("fixture", path, root: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked.swift").path, withDestinationPath: root.appendingPathComponent("Sources/Main.swift").path)
        let files = try ProjectFiles(project: project), expected = Set(["Sources/Main.swift", "README.md", ".gitignore"])
        XCTAssertEqual(Set(try files.inventory().files.map(\.path)), expected)
        XCTAssertEqual(Set(try files.inventory().files.map(\.path)), expected)
        XCTAssertEqual(try files.inventory(matching: "main").files.map(\.path), ["Sources/Main.swift"])
    }
    func testTraversalAbsolutePrivateAndSymlinkReadsAreRefused() throws {
        let (root, project) = try fixture(); try write("safe", "Safe.swift", root: root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/tmp")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Alias.swift").path, withDestinationPath: root.appendingPathComponent("Safe.swift").path)
        let files = try ProjectFiles(project: project)
        for path in ["../Safe.swift", "/etc/passwd", "./Safe.swift", "foo//bar.swift", ".env", "Alias.swift", "outside/test.swift", "new\nfile.swift"] {
            XCTAssertThrowsError(try files.read(path), path)
        }
        XCTAssertThrowsError(try ProjectFiles(project: DeveloperProject(name: "Disk", path: "/")))
        XCTAssertThrowsError(try ProjectFiles(project: DeveloperProject(name: "Home", path: NSHomeDirectory())))
    }
    func testReadIsNumberedBoundedAndRejectsInvalidRanges() throws {
        let (root, project) = try fixture(); try write((1...300).map { "line \($0)" }.joined(separator: "\n"), "Main.swift", root: root)
        let files = try ProjectFiles(project: project), excerpt = try files.read("Main.swift", startLine: 50)
        XCTAssertEqual(excerpt.startLine, 50); XCTAssertEqual(excerpt.endLine, 169); XCTAssertEqual(excerpt.totalLines, 300)
        XCTAssertTrue(excerpt.text.hasPrefix("50: line 50\n")); XCTAssertTrue(excerpt.shortened)
        XCTAssertThrowsError(try files.read("Main.swift", startLine: 0))
        XCTAssertThrowsError(try files.read("Main.swift", startLine: 301))
        XCTAssertThrowsError(try files.read("Main.swift", lineCount: 161))
    }
    func testLiteralSearchReturnsLineReferencesAndExplicitLimits() throws {
        let (root, project) = try fixture()
        try write("first\nFind [this]\nlast", "Main.swift", root: root)
        let files = try ProjectFiles(project: project), result = try files.search("[THIS]")
        XCTAssertEqual(result.matches.first?.path, "Main.swift"); XCTAssertEqual(result.matches.first?.line, 2)
        XCTAssertEqual(result.filesSearched, 1)
        try write(String(repeating: "needle\n", count: 100), "Many.swift", root: root)
        let bounded = try files.search("needle")
        XCTAssertEqual(bounded.matches.count, 30); XCTAssertTrue(bounded.incomplete)
        XCTAssertThrowsError(try files.search("   "))
    }
    func testRecognizedCredentialsBinaryOversizedAndSpecialFilesAreWithheld() throws {
        let (root, project) = try fixture()
        try write("let password = \"ThisIsNotARealPassword123\"", "Sensitive.swift", root: root)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.txt"))
        try write(String(repeating: "x", count: ProjectFiles.maximumFileBytes + 1), "Huge.swift", root: root)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.txt").path, 0o600), 0)
        let files = try ProjectFiles(project: project)
        for path in ["Sensitive.swift", "binary.txt", "Huge.swift", "pipe.txt"] { XCTAssertThrowsError(try files.read(path), path) }
        let result = try files.search("Password")
        XCTAssertTrue(result.matches.isEmpty); XCTAssertTrue(result.incomplete)
    }
    func testInventoryAndLongLineLimitsAreVisible() throws {
        let (root, project) = try fixture()
        try write("a", "A.swift", root: root); try write("b", "B.swift", root: root)
        let files = try ProjectFiles(project: project)
        XCTAssertTrue(try files.inventory(limit: 1).incomplete)
        try write(String(repeating: "x", count: 30_000), "Long.swift", root: root)
        let excerpt = try files.read("Long.swift")
        XCTAssertLessThanOrEqual(excerpt.text.count, 14_000); XCTAssertTrue(excerpt.shortened)
    }
    func testHeldRootAndNoFollowProtectAgainstReplacedDirectories() throws {
        let (root, project) = try fixture()
        try write("safe", "Sub/Main.swift", root: root)
        let files = try ProjectFiles(project: project)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sub"), to: root.appendingPathComponent("OldSub"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Sub").path, withDestinationPath: root.appendingPathComponent("OldSub").path)
        XCTAssertThrowsError(try files.read("Sub/Main.swift"))
        XCTAssertNoThrow(try files.read("OldSub/Main.swift"))
    }
    func testCancelledInspectionCannotReturnFileResults() async throws {
        let (_, project) = try fixture()
        let task = Task { try await ProjectInspection.run(.files(""), project: project) }; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSessionsAndProjectStateMigrateRoundTripAndBoundContext() throws {
        let (_, project) = try fixture()
        var state = AppSnapshot(); state.developerProjects = [project]; state.activeDeveloperProjectID = project.id
        var session = DevelopmentSession(projectID: project.id, title: "Crash on submit")
        session.observed = "An exception"; session.verification = "Reproduce with an empty request"; state.developmentSessions = [session]
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.activeDeveloperProject, project); XCTAssertEqual(decoded.developmentSessions, [session])
        let old = try JSONDecoder().decode(AppSnapshot.self, from: Data(#"{"schemaVersion":5}"#.utf8))
        XCTAssertTrue(old.developerProjects.isEmpty); XCTAssertTrue(old.developmentSessions.isEmpty)
        let context = decoded.developerContext(sessionID: session.id)
        XCTAssertTrue(context.contains("Crash on submit")); XCTAssertTrue(context.contains("An exception")); XCTAssertLessThanOrEqual(context.count, 11_000)
        session.title = " "; XCTAssertThrowsError(try session.validated())
    }
    func testPortableBackupIncludesSessionEvidenceButNeverFolderGrants() throws {
        let (_, project) = try fixture()
        var state = AppSnapshot(); state.developerProjects = [project]; state.activeDeveloperProjectID = project.id
        var session = DevelopmentSession(projectID: project.id, title: "Reproduce a failure"); session.findings = "Confirmed boundary condition"
        state.developmentSessions = [session]
        let data = try WorkspaceBackup.encode(state), preview = try WorkspaceBackup.inspect(data)
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot()).0
        XCTAssertTrue(restored.developerProjects.isEmpty); XCTAssertNil(restored.activeDeveloperProjectID)
        XCTAssertEqual(restored.developmentSessions.first?.findings, session.findings)
        XCTAssertNil(restored.developmentSessions.first?.projectID); XCTAssertEqual(restored.developmentSessions.first?.projectName, "Fixture")
        XCTAssertEqual(WorkspaceBackup.merging(preview, into: restored).0.developmentSessions.count, 1)
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let compressed = Data(base64Encoded: envelope["payload"] as! String)!
        let payload = String(decoding: try (compressed as NSData).decompressed(using: .lzfse) as Data, as: UTF8.self)
        XCTAssertFalse(payload.contains(project.path)); XCTAssertFalse(payload.contains("bookmark"))
    }
}

final class DeveloperGitTests: XCTestCase {
    private func fixture() throws -> (URL, DeveloperProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-git-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-b", "main"], root: root)
        return (root, DeveloperProject(name: "Git fixture", path: root.path))
    }
    private func git(_ args: [String], root: URL) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/git"); task.currentDirectoryURL = root
        task.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null"] + args
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit(); XCTAssertEqual(task.terminationStatus, 0)
    }
    func testWorkingAndStagedDiffsUseDifferentCapturedBaselines() async throws {
        let (root, project) = try fixture(), file = root.appendingPathComponent("Main.swift")
        try Data("let value = 1\n".utf8).write(to: file); try git(["add", "Main.swift"], root: root); try git(["commit", "-qm", "Initial"], root: root)
        try Data("let value = 2\n".utf8).write(to: file); try git(["add", "Main.swift"], root: root)
        try Data("let value = 3\n".utf8).write(to: file)
        let files = try ProjectFiles(project: project)
        let status = try await ProjectGit.status(files)
        XCTAssertEqual(status.branch, "main"); XCTAssertEqual(status.files.first?.status, "MM")
        let working = try await ProjectGit.diff(files, path: "Main.swift", staged: false)
        XCTAssertTrue(working.text.contains("-let value = 2")); XCTAssertTrue(working.text.contains("+let value = 3"))
        let staged = try await ProjectGit.diff(files, path: "Main.swift", staged: true)
        XCTAssertTrue(staged.text.contains("-let value = 1")); XCTAssertTrue(staged.text.contains("+let value = 2"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 3\n")
    }
    func testPrivatePathsExcludedAndExternalGitHelpersNeverExecute() async throws {
        let (root, project) = try fixture()
        try Data("source".utf8).write(to: root.appendingPathComponent("Main.swift"))
        try Data("private".utf8).write(to: root.appendingPathComponent(".env"))
        let marker = root.appendingPathComponent("should-not-run")
        try git(["config", "core.fsmonitor", "touch \(marker.path)"], root: root)
        let files = try ProjectFiles(project: project), status = try await ProjectGit.status(files)
        XCTAssertEqual(status.files.map(\.path), ["Main.swift"]); XCTAssertEqual(status.excluded, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        do { _ = try await ProjectGit.diff(files, path: ".env", staged: false); XCTFail("Private path") } catch {}
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Link.swift").path, withDestinationPath: "Main.swift")
        try git(["add", "Link.swift"], root: root)
        do { _ = try await ProjectGit.diff(files, path: "Link.swift", staged: true); XCTFail("Staged symlink") }
        catch { XCTAssertTrue(error.localizedDescription.contains("symbolic")) }
    }
    func testNewAndDeletedTextAndHeaderReplacementDoNotChangeSourceLines() async throws {
        let (root, project) = try fixture(), file = root.appendingPathComponent("Main.swift")
        try Data("let path = \"a/before\"\n".utf8).write(to: file)
        let files = try ProjectFiles(project: project)
        let fresh = try await ProjectGit.diff(files, path: "Main.swift", staged: false)
        XCTAssertTrue(fresh.text.contains("+let path = \"a/before\"")); XCTAssertTrue(fresh.text.contains("b/Main.swift"))
        try git(["add", "Main.swift"], root: root); try git(["commit", "-qm", "Initial"], root: root)
        try FileManager.default.removeItem(at: file)
        let deleted = try await ProjectGit.diff(files, path: "Main.swift", staged: false)
        XCTAssertTrue(deleted.text.contains("-let path"))
    }
    func testHistoricCredentialContentIsWithheldEvenWhenWorkingCopyIsClean() async throws {
        let (root, project) = try fixture(), file = root.appendingPathComponent("Main.swift")
        try Data("let password = \"NotARealPassword12345\"\n".utf8).write(to: file)
        try git(["add", "Main.swift"], root: root)
        try Data("let safe = true\n".utf8).write(to: file)
        do { _ = try await ProjectGit.diff(ProjectFiles(project: project), path: "Main.swift", staged: false); XCTFail("Secret baseline must be withheld") }
        catch { XCTAssertTrue(error.localizedDescription.contains("credential")) }
    }
    func testMissingPartialCloneObjectCannotRunARemoteHelper() async throws {
        let (root, project) = try fixture(), file = root.appendingPathComponent("Main.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try git(["add", "Main.swift"], root: root); try git(["commit", "-qm", "Initial"], root: root)
        let query = Process(), pipe = Pipe()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/git"); query.currentDirectoryURL = root
        query.arguments = ["rev-parse", "HEAD:Main.swift"]; query.standardOutput = pipe
        try query.run(); query.waitUntilExit()
        let hash = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = root.appendingPathComponent(".git/objects/\(hash.prefix(2))/\(hash.dropFirst(2))")
        try FileManager.default.removeItem(at: object)
        let marker = root.appendingPathComponent("remote-helper-ran")
        for args in [["core.repositoryformatversion", "1"], ["extensions.partialClone", "origin"],
            ["remote.origin.promisor", "true"], ["remote.origin.url", "ext::touch \(marker.path)"], ["protocol.ext.allow", "always"]] {
            try git(["config"] + args, root: root)
        }
        do { _ = try await ProjectGit.diff(ProjectFiles(project: project), path: "Main.swift", staged: true); XCTFail("Missing object must fail without fetching") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
