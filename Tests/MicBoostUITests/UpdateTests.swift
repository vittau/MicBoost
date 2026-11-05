import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

private let updatePage = URL(string: "https://github.com/vittau/MicBoost/releases/tag/v1.2.3")!

private func release(_ tag: String, page: URL = updatePage) -> Release {
    Release(tag: tag, pageURL: page)
}

/// Responses handed out in order; every call is counted, so a test can prove how many
/// requests the app made. No test reaches the network.
actor ScriptedReleaseFeed: ReleaseFeed {
    enum Response: Sendable {
        case release(Release)
        case failure
    }

    private var responses: [Response]
    private(set) var requestCount = 0

    init(_ responses: [Response]) { self.responses = responses }

    func latestRelease() async throws -> Release {
        requestCount += 1
        guard !responses.isEmpty else { throw ReleaseFeedError.invalidPayload }
        switch responses.removeFirst() {
        case .release(let release): return release
        case .failure: throw ReleaseFeedError.badStatus(500)
        }
    }
}

/// Holds the first request open so a second "Check Now" arrives while one is in flight.
actor GatedReleaseFeed: ReleaseFeed {
    private let value: Release
    private(set) var requestCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?

    init(release: Release) { self.value = release }

    func latestRelease() async throws -> Release {
        requestCount += 1
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withCheckedContinuation { finishWaiter = $0 }
        return value
    }

    func waitForStart() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

/// Records every wait and advances a frozen clock by it. `cancelledOnWait` is the 1-based
/// wait that reports cancellation, ending the schedule loop.
final class FakeUpdateScheduler: UpdateScheduler, @unchecked Sendable {
    private(set) var waits: [Duration] = []
    private let cancelledOnWait: Int
    private var clock: Date

    init(now: Date, cancelledOnWait: Int) {
        self.clock = now
        self.cancelledOnWait = cancelledOnWait
    }

    var now: Date { clock }

    func sleep(for duration: Duration) async -> Bool {
        waits.append(duration)
        clock = clock.addingTimeInterval(duration.timeInterval)
        return waits.count != cancelledOnWait
    }
}

/// In-memory settings storage, so no suite writes to the developer's defaults.
final class UpdateTestStorage: SettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    func setData(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

@MainActor private func updateModel(
    feed: any ReleaseFeed,
    scheduler: any UpdateScheduler,
    appVersion: String = "1.0.0",
    checkForUpdates: Bool = true
) -> AppModel {
    let model = AppModel(
        store: SettingsStore(storage: UpdateTestStorage()),
        statusGrace: .zero,
        loginItem: FakeLoginItemService(),
        appVersion: appVersion,
        updateFeed: feed,
        updateScheduler: scheduler)
    model.controls.checkForUpdates = checkForUpdates
    return model
}

@MainActor struct UpdateTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func automaticCheckRunsAfterThirtySecondsAndEveryDay() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.0.0")), .release(release("v1.0.0"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 3)
        let model = updateModel(feed: feed, scheduler: scheduler)

        await model.runUpdateSchedule()

        #expect(scheduler.waits == [.seconds(30), .seconds(86_400), .seconds(86_400)])
        #expect(await feed.requestCount == 2)
    }

    @Test func automaticCheckIsSkippedWithTheToggleOff() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 3)
        let model = updateModel(feed: feed, scheduler: scheduler, checkForUpdates: false)

        await model.runUpdateSchedule()

        #expect(await feed.requestCount == 0)
        #expect(model.updateStatus == .idle)
    }

    @Test func automaticCheckWaitsADayWhenTheLastCheckIsRecent() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 2)
        let model = updateModel(feed: feed, scheduler: scheduler)
        model.controls.lastUpdateCheck = Self.start.addingTimeInterval(-3_600)

        await model.runUpdateSchedule()

        #expect(scheduler.waits == [.seconds(30), .seconds(86_400)])
        #expect(await feed.requestCount == 0)
    }

    @Test func manualCheckRunsWithTheToggleOff() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler, checkForUpdates: false)

        model.checkNow()
        await model.finishUpdateCheck()

        #expect(await feed.requestCount == 1)
        #expect(model.availableUpdate?.version == "1.2.3")
        #expect(model.availableUpdate?.url == updatePage)
        #expect(model.controls.lastUpdateCheck == Self.start)
    }

    @Test func onlyOneRequestRunsAtATime() async {
        let feed = GatedReleaseFeed(release: release("v1.2.3"))
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        model.checkNow()
        await feed.waitForStart()
        #expect(model.isCheckingUpdate)
        model.checkNow()
        #expect(await feed.requestCount == 1)

        await feed.finish()
        await model.finishUpdateCheck()
        #expect(!model.isCheckingUpdate)
        #expect(await feed.requestCount == 1)
        #expect(model.availableUpdate?.version == "1.2.3")
    }

    @Test func automaticFailureIsSilent() async {
        let feed = ScriptedReleaseFeed([.failure])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        #expect(!(await model.performUpdateCheck(manual: false)))
        #expect(model.updateStatus == .idle)
        #expect(model.updateStatusText == nil)
    }

    @Test func manualFailureShowsTheMessage() async {
        let feed = ScriptedReleaseFeed([.failure])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        #expect(!(await model.performUpdateCheck(manual: true)))
        #expect(model.updateStatus == .failed)
        #expect(model.updateStatusText == localized("Couldn't check for updates."))
    }

    @Test func upToDateStoresTheCheckDate() async throws {
        let feed = ScriptedReleaseFeed([.release(release("v1.0.0"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        #expect(await model.performUpdateCheck(manual: true))
        #expect(model.updateStatus == .upToDate(Self.start))
        #expect(model.availableUpdate == nil)
        #expect(model.controls.lastUpdateCheck == Self.start)
        #expect(await model.store.current.lastUpdateCheck == Self.start)
        #expect(model.updateStatusText != nil)
    }

    @Test func newerReleaseIsReportedWithItsPage() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        #expect(await model.performUpdateCheck(manual: true))
        #expect(model.availableUpdate == AvailableUpdate(version: "1.2.3", url: updatePage))
        #expect(model.updateStatusText == String(format: localized("Version %@ available."), "1.2.3"))
    }

    @Test func invalidTagCountsAsUpToDate() async {
        let feed = ScriptedReleaseFeed([.release(release("nightly"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)

        #expect(await model.performUpdateCheck(manual: true))
        #expect(model.availableUpdate == nil)
        #expect(model.updateStatus == .upToDate(Self.start))
    }

    @Test func panelItemOnlyExistsWithANewerRelease() async throws {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)
        let panel = PanelMenuController(model: model)
        let title = String(format: localized("New version available: %@…"), "1.2.3")

        #expect(!panel.menu.items.contains { $0.title == title })

        #expect(await model.performUpdateCheck(manual: true))
        panel.refresh()
        let item = try #require(panel.menu.items.first { $0.title == title })
        #expect(item.action != nil)
    }

    @Test func panelItemClickOpensTheReleasePage() async throws {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)
        #expect(await model.performUpdateCheck(manual: true))

        var opened: URL?
        model.openURL = { opened = $0 }
        let panel = PanelMenuController(model: model)
        panel.refresh()
        let title = String(format: localized("New version available: %@…"), "1.2.3")
        let index = try #require(panel.menu.items.firstIndex { $0.title == title })

        panel.menu.performActionForItem(at: index)
        #expect(opened == updatePage)
    }

    @Test func settingsDownloadOpensTheReleasePage() async {
        let feed = ScriptedReleaseFeed([.release(release("v1.2.3"))])
        let scheduler = FakeUpdateScheduler(now: Self.start, cancelledOnWait: 0)
        let model = updateModel(feed: feed, scheduler: scheduler)
        #expect(await model.performUpdateCheck(manual: true))

        var opened: URL?
        model.openURL = { opened = $0 }
        model.openUpdatePage()
        #expect(opened == updatePage)
    }
}
