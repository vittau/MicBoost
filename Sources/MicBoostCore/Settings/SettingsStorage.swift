import Foundation

/// Bytes-level storage behind `SettingsStore`.
///
/// Tests use an in-memory implementation; the app uses `UserDefaultsStorage`.
public protocol SettingsStorage: Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}

// `UserDefaults` is documented thread-safe; `SettingsStore` is the only caller,
// and it does so from its own actor. No mutable state lives in this wrapper.
public final class UserDefaultsStorage: SettingsStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func setData(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
