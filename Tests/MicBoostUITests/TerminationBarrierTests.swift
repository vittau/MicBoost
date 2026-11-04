import AppKit
import MicBoostCore
import Testing

@testable import MicBoostUI

/// Receives the barrier's single reply.
///
/// The reply runs on the main actor. The UI suites share that actor, and their AppKit work can
/// hold the main thread for seconds on the CI runner, so a poll with a wall-clock budget gives
/// up while the reply is still queued behind them. Waiting for the reply event itself has no
/// budget to lose (docs/testing.md "MicBoostUITests").
@MainActor private final class ReplyWaiter {
    private var answered = false
    private var value: Bool?
    private var waiter: CheckedContinuation<Bool?, Never>?

    func record(_ granted: Bool?) {
        answered = true
        value = granted
        waiter?.resume(returning: granted)
        waiter = nil
    }

    /// The hang guard only turns a barrier that never answers into a failure instead of a stuck
    /// test run; it is not a timing assertion.
    func wait(hangGuard: Duration = .seconds(30)) async -> Bool? {
        if answered { return value }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: hangGuard)
            guard !Task.isCancelled else { return }
            Issue.record("the termination barrier never answered; the quit is not bounded")
            self?.record(nil)
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Quitting is a voluntary stop: the app must not exit before the restore ran
/// (docs/architecture.md "Interface do app").
@MainActor @Test func quitAnswersOnlyAfterTheStopFinished() async {
    var events: [String] = []
    let reply = ReplyWaiter()
    let barrier = TerminationBarrier(
        deadline: .seconds(2),
        shutdown: { events.append("stop") },
        reply: { granted in
            events.append("reply:\(granted)")
            reply.record(granted)
        })

    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await reply.wait() == true)
    #expect(events == ["stop", "reply:true"], "the reply must come after the stop: \(events)")

    // AppKit asked once; an already answered barrier forces the termination.
    #expect(barrier.shouldTerminate() == .terminateNow)
}

/// A second ⌘Q while the stop runs must not cut the restore short.
@MainActor @Test func repeatedQuitKeepsWaiting() async {
    var replies = 0
    let reply = ReplyWaiter()
    let barrier = TerminationBarrier(
        deadline: .seconds(2), shutdown: { try? await Task.sleep(for: .milliseconds(50)) },
        reply: { _ in
            replies += 1
            reply.record(true)
        })

    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await reply.wait() != nil)
    #expect(replies == 1)
}

/// A hung HAL call must not leave a quit that never ends.
@MainActor @Test func quitIsBoundedByTheDeadline() async {
    var stopRunning = true
    var repliedWhileStopping = false
    let reply = ReplyWaiter()
    let barrier = TerminationBarrier(
        deadline: .milliseconds(80),
        shutdown: {
            try? await Task.sleep(for: .seconds(30))
            stopRunning = false
        },
        reply: { granted in
            repliedWhileStopping = stopRunning
            reply.record(granted)
        })

    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await reply.wait() == true)
    // The reply came while the stop was still suspended: the deadline, not the stop, answered.
    #expect(repliedWhileStopping)
}

/// A failed stop still terminates: the persisted recovery state keeps the next stop able to restore.
@MainActor @Test func failedStopStillQuits() async {
    var answered: Bool?
    let barrier = TerminationBarrier(
        deadline: .seconds(2),
        shutdown: { throw EngineError.halFailure(-1, "stop") },
        reply: { answered = $0 })

    await barrier.run()
    #expect(answered == true)
}
