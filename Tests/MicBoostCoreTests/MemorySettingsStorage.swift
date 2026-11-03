import Foundation

@testable import MicBoostCore

/// In-memory `SettingsStorage` for tests.
///
/// Guarded by a lock: `SettingsStore` is an actor and writes from its own
/// executor while the test reads the counts. No other mutable state exists, so
/// `@unchecked Sendable` is limited to that lock discipline.
final class MemorySettingsStorage: SettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writeCount = 0

    /// Number of `setData` calls, including the debounced ones.
    var writes: Int { lock.withLock { writeCount } }

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    func setData(_ data: Data?, forKey key: String) {
        lock.withLock {
            values[key] = data
            writeCount += 1
        }
    }

    /// Puts data in place without counting as a store write.
    func seed(_ data: Data?) {
        lock.withLock { values[SettingsStore.storageKey] = data }
    }

    func seed(_ settings: Settings) throws {
        seed(try JSONEncoder().encode(settings))
    }

    /// Decoded persisted settings, or `nil` when nothing valid was written.
    var decoded: Settings? {
        guard let data = data(forKey: SettingsStore.storageKey) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
}
