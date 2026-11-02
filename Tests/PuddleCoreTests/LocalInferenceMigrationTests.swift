import Foundation
import XCTest
import PuddleCore

private final class MigrationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrites = false
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws {
        try lock.withLock {
            if failWrites { throw PuddleError("Fixture write failure") }
            values[key] = data
        }
    }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class LocalInferenceMigrationTests: XCTestCase {
    func testOldCredentialMovesToGenericKeyAndCannotReturnAfterClearing() throws {
        let secrets = MigrationSecrets(), value = Data("local-test-key".utf8)
        try secrets.write(value, key: "splash-key")
        XCTAssertEqual(try LocalInferenceCredentials.load(from: secrets), value)
        XCTAssertNil(try secrets.read("splash-key"))
        XCTAssertEqual(try secrets.read(LocalInferenceCredentials.key), value)
        try secrets.delete(LocalInferenceCredentials.key)
        XCTAssertNil(try LocalInferenceCredentials.load(from: secrets))
    }

    func testNewCredentialAndAddressTakePrecedenceOverLegacyValues() throws {
        let secrets = MigrationSecrets(), value = Data("current-test-key".utf8)
        try secrets.write(Data("old-test-key".utf8), key: "splash-key")
        try secrets.write(value, key: LocalInferenceCredentials.key)
        XCTAssertEqual(try LocalInferenceCredentials.load(from: secrets), value)
        XCTAssertNil(try secrets.read("splash-key"))
        let settings = try JSONDecoder().decode(PuddleSettings.self, from: Data(#"{"inferenceAddress":"http://localhost:1234","splashAddress":"http://localhost:8000"}"#.utf8))
        XCTAssertEqual(settings.inferenceAddress, "http://localhost:1234")
    }

    func testFailedCredentialMigrationPreservesOriginalUntilRetry() throws {
        let secrets = MigrationSecrets(), value = Data("local-test-key".utf8)
        try secrets.write(value, key: "splash-key")
        secrets.failWrites = true
        XCTAssertThrowsError(try LocalInferenceCredentials.load(from: secrets))
        XCTAssertEqual(try secrets.read("splash-key"), value)
        XCTAssertNil(try secrets.read(LocalInferenceCredentials.key))
        secrets.failWrites = false
        XCTAssertEqual(try LocalInferenceCredentials.load(from: secrets), value)
        XCTAssertNil(try secrets.read("splash-key"))
    }
}
