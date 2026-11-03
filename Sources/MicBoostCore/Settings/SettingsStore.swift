import Foundation

/// Reads and writes `Settings` with the rules of docs/architecture.md "Persistência".
///
/// An actor, because the engine controller mutates settings from its own queue
/// while the UI reads them through it. Writes of regular fields are coalesced by
/// a 300 ms debounce; the default-input recovery fields are written immediately.
public actor SettingsStore {
    public static let storageKey = "io.github.vittau.MicBoost.settings"

    private let storage: any SettingsStorage
    private let debounceInterval: Duration
    private var settings: Settings
    private var pendingWrite: Task<Void, Never>?

    /// Loads the stored settings; unknown schema or corrupt data falls back to defaults.
    public init(
        storage: any SettingsStorage,
        debounceInterval: Duration = .milliseconds(300)
    ) {
        self.storage = storage
        self.debounceInterval = debounceInterval
        self.settings = Self.load(from: storage)
    }

    /// Last accepted values, including changes still waiting for the debounce.
    public var current: Settings { settings }

    /// Mutates regular fields and schedules the debounced write.
    @discardableResult
    public func update(_ mutate: @Sendable (inout Settings) -> Void) -> Settings {
        var next = settings
        mutate(&next)
        return apply(next, immediately: false)
    }

    /// Mutates the default-input recovery fields and writes them without debounce.
    @discardableResult
    public func updateDefaultInput(_ mutate: @Sendable (inout Settings) -> Void) -> Settings {
        var next = settings
        mutate(&next)
        return apply(next, immediately: true)
    }

    /// Writes any pending change now.
    public func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func apply(_ next: Settings, immediately: Bool) -> Settings {
        guard next != settings else { return settings }
        settings = next
        if immediately {
            pendingWrite?.cancel()
            pendingWrite = nil
            write()
        } else {
            scheduleWrite()
        }
        return settings
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            self.write()
        }
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        storage.setData(data, forKey: Self.storageKey)
    }

    private static func load(from storage: any SettingsStorage) -> Settings {
        guard let data = storage.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode(Settings.self, from: data),
            stored.schemaVersion == Settings.currentSchemaVersion
        else {
            return Settings()
        }
        return stored.sanitized()
    }
}
