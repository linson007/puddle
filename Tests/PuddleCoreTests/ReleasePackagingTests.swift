import Foundation
import XCTest

/// Run the actual release orchestrator against disposable tools. Nothing is signed,
/// uploaded or notarized; these checks protect the build and publication boundary.
final class ReleasePackagingTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-release-\(UUID())")
        var output: URL { root.appendingPathComponent("build/releases/1.0.0-10") }
        init() throws {
            let scripts = root.appendingPathComponent("scripts"), bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: source.appendingPathComponent("scripts/release.sh"), to: scripts.appendingPathComponent("release.sh"))
            try executable(scripts.appendingPathComponent("build.sh"), """
            #!/bin/sh
            set -eu
            printf '%s' "${PUDDLE_BUILD_CONFIGURATION:-release}" > "$FIXTURE_ROOT/configuration"
            mkdir -p "$FIXTURE_ROOT/build/Puddle.app"
            """)
            for name in ["codesign", "spctl", "ditto", "xcrun"] {
                try executable(bin.appendingPathComponent(name), """
                #!/bin/sh
                set -eu
                tool=${0##*/}
                printf '%s %s\\n' "$tool" "$*" >> "$FIXTURE_ROOT/commands"
                case "$tool" in
                  ditto) for last do :; done; printf 'synthetic archive' > "$last" ;;
                  xcrun) if [ "$1" = notarytool ]; then printf '{"status":"%s"}' "${FIXTURE_NOTARY_STATUS:-Accepted}"; fi ;;
                esac
                """)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        private func executable(_ url: URL, _ text: String) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        func run(_ overrides: [String: String] = [:]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [root.appendingPathComponent("scripts/release.sh").path]
            process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "FIXTURE_ROOT": root.path,
                "PUDDLE_SIGNING_IDENTITY": "Developer ID Application: Synthetic (TEST)", "PUDDLE_NOTARY_PROFILE": "fixture",
                "PUDDLE_VERSION": "1.0.0", "PUDDLE_BUILD_NUMBER": "10"].merging(overrides) { _, new in new }
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    func testPublicReleaseForcesOptimizedBuildEvenWhenDebugIsInherited() throws {
        let fixture = try Fixture(), result = try fixture.run(["PUDDLE_BUILD_CONFIGURATION": "debug"])
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("configuration"), encoding: .utf8), "release")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Puddle-1.0.0.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("SHA256SUMS").path))
    }

    func testRejectedNotarizationNeverCreatesDistributableArchive() throws {
        let fixture = try Fixture(), result = try fixture.run(["FIXTURE_NOTARY_STATUS": "Invalid"])
        XCTAssertNotEqual(result.0, 0)
        XCTAssertTrue(result.1.contains("Apple did not accept"), result.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Puddle-1.0.0.zip").path))
        let commands = try String(contentsOf: fixture.root.appendingPathComponent("commands"), encoding: .utf8)
        XCTAssertFalse(commands.contains("stapler")); XCTAssertFalse(commands.contains("spctl"))
    }

    func testAdHocIdentityAndExistingReleaseAreRejectedBeforeBuild() throws {
        let fixture = try Fixture()
        XCTAssertNotEqual(try fixture.run(["PUDDLE_SIGNING_IDENTITY": "-"]).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("configuration").path))
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let marker = fixture.output.appendingPathComponent("keep.txt")
        try Data("preserve previous release".utf8).write(to: marker)
        XCTAssertNotEqual(try fixture.run().0, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve previous release")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("configuration").path))
    }
}
