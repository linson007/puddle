import Foundation

/// Read old connection settings once; new workspaces use provider-neutral names.
enum LegacyInferenceConfiguration {
    private enum Keys: String, CodingKey { case address = "splashAddress" }
    static func address(from decoder: Decoder) throws -> String? {
        try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .address)
    }
}

public enum LocalInferenceCredentials {
    public static let key = "local-inference-key"
    private static let legacyKey = "splash-key"

    /// Write before deleting so a failed migration never discards the saved key.
    public static func load(from store: any SecretStore) throws -> Data? {
        let current = try store.read(key)
        guard let legacy = try store.read(legacyKey) else { return current }
        if current == nil { try store.write(legacy, key: key) }
        try store.delete(legacyKey)
        return current ?? legacy
    }
}
