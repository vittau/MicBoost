import AppKit
import Foundation
import os

/// Holds the termination of the menu bar app until the engine stopped and the default input was
/// restored (docs/architecture.md "Interface do app").
///
/// `applicationShouldTerminate` returns `.terminateLater`, this barrier runs `AppModel.shutdown`
/// and only then calls `reply(toApplicationShouldTerminate:)`, so the process never exits between
/// destroying the aggregate and writing the previous default input back.
///
/// The wait is bounded by `deadline`: a HAL call that never returns must not leave a quit that
/// never ends. Once the deadline passes the app terminates anyway, and the persisted recovery
/// state still allows the next voluntary stop to restore the input (docs/audio-engine.md
/// "Política de entrada padrão"). A failed stop also terminates, for the same reason.
@MainActor
public final class TerminationBarrier {
    /// Longest wait for the stop, the restore and the settings flush.
    public static let deadline: Duration = .seconds(5)

    private let log = Logger(subsystem: "io.github.vittau.MicBoost", category: "lifecycle")
    private let deadline: Duration
    private let shutdown: @MainActor () async throws -> Void
    private let reply: @MainActor (Bool) -> Void
    /// AppKit asked for the termination and the stop already started.
    private var requested = false
    private var running = false
    /// AppKit was already answered; the process is on its way out.
    private var answered = false

    public init(
        deadline: Duration = TerminationBarrier.deadline,
        shutdown: @escaping @MainActor () async throws -> Void,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        self.deadline = deadline
        self.shutdown = shutdown
        self.reply = reply
    }

    /// Answer of `applicationShouldTerminate`.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        if answered { return .terminateNow }
        if requested { return .terminateLater }
        requested = true
        Task { await run() }
        return .terminateLater
    }

    /// Runs the stop and answers AppKit once. Called by `shouldTerminate`, and directly by the
    /// tests that need to await it.
    public func run() async {
        guard !running, !answered else { return }
        running = true
        let timeout = Task { @MainActor [deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            log.error("quit deadline reached with the engine stop unfinished")
            answer()
        }
        do {
            try await shutdown()
        } catch {
            log.error("quit after a failed stop: \(String(describing: error), privacy: .public)")
        }
        timeout.cancel()
        answer()
    }

    private func answer() {
        guard !answered else { return }
        answered = true
        running = false
        reply(true)
    }
}
