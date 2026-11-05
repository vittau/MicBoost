import Foundation

/// A newer release known by the update check (docs/architecture.md "Verificação de atualizações").
public struct AvailableUpdate: Equatable, Sendable {
    /// Version without the leading `v`, ready to show.
    public var version: String
    /// Release page opened by the panel item and by "Download".
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// What the settings status line and the panel item show for the update check.
public enum UpdateStatus: Equatable, Sendable {
    /// No check finished in this session.
    case idle
    case checking
    /// The installed version is current; the date is the last valid check.
    case upToDate(Date)
    case available(AvailableUpdate)
    /// A check requested by the user failed.
    case failed
}

/// Clock and waits of the update schedule, injected so tests run it without sleeping.
public protocol UpdateScheduler: Sendable {
    var now: Date { get }
    /// Waits for `duration`; `false` means the wait was cancelled (the app is quitting).
    func sleep(for duration: Duration) async -> Bool
}

public struct SystemUpdateScheduler: UpdateScheduler {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async -> Bool {
        (try? await Task.sleep(for: duration)) != nil
    }
}
