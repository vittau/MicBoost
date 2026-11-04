import AppKit
import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

/// Polls a condition that depends on the main actor.
@MainActor private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Quitting is a voluntary stop: the app must not exit before the restore ran
/// (docs/architecture.md "Interface do app").
@MainActor @Test func quitAnswersOnlyAfterTheStopFinished() async {
    var events: [String] = []
    let barrier = TerminationBarrier(
        deadline: .seconds(2),
        shutdown: { events.append("stop") },
        reply: { events.append("reply:\($0)") })

    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await waitUntil { events.count == 2 })
    #expect(events == ["stop", "reply:true"], "the reply must come after the stop: \(events)")

    // AppKit asked once; an already answered barrier forces the termination.
    #expect(barrier.shouldTerminate() == .terminateNow)
}

/// A second ⌘Q while the stop runs must not cut the restore short.
@MainActor @Test func repeatedQuitKeepsWaiting() async {
    var replies = 0
    let barrier = TerminationBarrier(
        deadline: .seconds(2), shutdown: { try? await Task.sleep(for: .milliseconds(50)) },
        reply: { _ in replies += 1 })

    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await waitUntil { replies == 1 })
    #expect(replies == 1)
}

/// A hung HAL call must not leave a quit that never ends.
@MainActor @Test func quitIsBoundedByTheDeadline() async {
    var replied = false
    let barrier = TerminationBarrier(
        deadline: .milliseconds(80), shutdown: { try? await Task.sleep(for: .seconds(30)) },
        reply: { replied = $0 })

    let start = ContinuousClock.now
    #expect(barrier.shouldTerminate() == .terminateLater)
    #expect(await waitUntil(timeout: .seconds(2)) { replied })
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(replied)
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
