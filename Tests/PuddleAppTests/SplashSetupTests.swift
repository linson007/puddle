import Foundation
import XCTest
@testable import Puddle
import PuddleCore

@MainActor final class SplashSetupTests: XCTestCase {
    func testManagedProcessHasBoundedLogAndCanBeStoppedWithoutTouchingExistingServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-splash")
        try Data("#!/usr/bin/python3\nimport time\nprint('Fixture ready', flush=True)\ntime.sleep(30)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let hardware = LocalAIHardware(chip: "Apple M5", memoryBytes: 48 * 1_073_741_824, freeDiskBytes: 100 * 1_073_741_824,
            os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        let suite = "puddle-setup-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let setup = SplashSetupController(hardware: hardware, preferences: preferences); setup.executable = executable.path
        setup.start(preset: .balanced, port: 18000)
        XCTAssertTrue(setup.ownsServer)
        for _ in 0..<100 where !setup.output.contains("Fixture ready") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(setup.output.contains("Fixture ready"))
        setup.stop()
        for _ in 0..<100 where setup.ownsServer { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(setup.ownsServer)
        setup.stop(); XCTAssertFalse(setup.ownsServer)
    }
}
