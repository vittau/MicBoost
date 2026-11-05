import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

/// Login item behind the settings toggle (docs/architecture.md "Item de início" and
/// docs/ui.md "Janela de ajustes"). The fake never touches `SMAppService`, so no test
/// registers the app or changes the maintainer's login items.
final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Login item change failed." }
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() { openSystemSettingsCount += 1 }
}

/// In-memory storage for the settings of one test.
final class LoginItemStorage: SettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    func setData(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }

    func seed(_ settings: Settings) throws {
        setData(try JSONEncoder().encode(settings), forKey: SettingsStore.storageKey)
    }

    var decoded: Settings? {
        guard let data = data(forKey: SettingsStore.storageKey) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
}

@MainActor struct LoginItemTests {
    private static let applicationsBundle = URL(fileURLWithPath: "/Applications/MicBoost.app")
    private static let downloadsBundle = URL(fileURLWithPath: "/Users/someone/Downloads/MicBoost.app")

    private static func model(
        store: SettingsStore,
        loginItem: FakeLoginItemService,
        bundleURL: URL = applicationsBundle
    ) -> AppModel {
        AppModel(
            store: store, statusGrace: .zero, loginItem: loginItem, loginItemBundleURL: bundleURL)
    }

    @Test func defaultIsAppliedOnceInsideApplications() async throws {
        let storage = LoginItemStorage()
        let store = SettingsStore(storage: storage)
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: store, loginItem: loginItem)

        #expect(await model.applyLoginItemDefaultIfNeeded())
        #expect(loginItem.registerCount == 1)
        #expect(loginItem.status == .enabled)
        #expect(model.controls.loginItemDefaultApplied)
        #expect(storage.decoded?.loginItemDefaultApplied == true)

        #expect(!(await model.applyLoginItemDefaultIfNeeded()))
        #expect(loginItem.registerCount == 1)
    }

    @Test func defaultIsNotReappliedOnALaterLaunch() async throws {
        let storage = LoginItemStorage()
        let first = FakeLoginItemService()
        #expect(
            await Self.model(store: SettingsStore(storage: storage), loginItem: first)
                .applyLoginItemDefaultIfNeeded())

        let second = FakeLoginItemService()
        let next = Self.model(store: SettingsStore(storage: storage), loginItem: second)
        #expect(!(await next.applyLoginItemDefaultIfNeeded()))
        #expect(second.registerCount == 0)
    }

    @Test func defaultIsNeverAppliedOutsideApplications() async throws {
        let storage = LoginItemStorage()
        let store = SettingsStore(storage: storage)
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: store, loginItem: loginItem, bundleURL: Self.downloadsBundle)

        #expect(!model.loginItemAvailable)
        #expect(!(await model.applyLoginItemDefaultIfNeeded()))
        #expect(loginItem.registerCount == 0)
        #expect(storage.decoded?.loginItemDefaultApplied != true)
        #expect(!model.controls.loginItemDefaultApplied)

        // The toggle cannot register from outside Applications either.
        model.setLoginItemEnabled(true)
        #expect(loginItem.registerCount == 0)
    }

    @Test func defaultFlagIsStoredEvenWhenRegisterFails() async throws {
        let storage = LoginItemStorage()
        let store = SettingsStore(storage: storage)
        let loginItem = FakeLoginItemService()
        loginItem.registerError = FakeLoginItemService.Failure()
        let model = Self.model(store: store, loginItem: loginItem)

        #expect(await model.applyLoginItemDefaultIfNeeded())
        #expect(loginItem.registerCount == 1)
        #expect(model.loginItemOn == false)
        #expect(storage.decoded?.loginItemDefaultApplied == true)
    }

    @Test func defaultIsNotReappliedAfterTheUserTurnsItOff() async throws {
        let storage = LoginItemStorage()
        try storage.seed(Settings(loginItemDefaultApplied: true))
        let loginItem = FakeLoginItemService()
        loginItem.status = .enabled
        let model = Self.model(store: SettingsStore(storage: storage), loginItem: loginItem)

        model.refreshLoginItemStatus()
        #expect(model.loginItemOn)
        model.setLoginItemEnabled(false)
        #expect(loginItem.unregisterCount == 1)
        #expect(!model.loginItemOn)

        #expect(!(await model.applyLoginItemDefaultIfNeeded()))
        #expect(loginItem.registerCount == 0)
        #expect(loginItem.status == .notRegistered)
    }

    @Test func theFourStatesMapToTheToggle() {
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: SettingsStore(storage: LoginItemStorage()), loginItem: loginItem)

        for (status, isOn) in [
            (LoginItemStatus.enabled, true),
            (.requiresApproval, true),
            (.notRegistered, false),
            (.notFound, false),
        ] {
            loginItem.status = status
            model.refreshLoginItemStatus()
            #expect(model.loginItemOn == isOn, "\(status)")
            #expect(model.loginItemRequiresApproval == (status == .requiresApproval), "\(status)")
            #expect(model.loginItemError == nil)
        }
    }

    @Test func registerFailureKeepsTheRealStateAndShowsTheError() {
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: SettingsStore(storage: LoginItemStorage()), loginItem: loginItem)
        model.refreshLoginItemStatus()
        loginItem.registerError = FakeLoginItemService.Failure()

        model.setLoginItemEnabled(true)
        #expect(model.loginItemStatus == .notRegistered)
        #expect(!model.loginItemOn)
        #expect(model.loginItemError == "Login item change failed.")
    }

    @Test func unregisterFailureKeepsTheRealStateAndShowsTheError() {
        let loginItem = FakeLoginItemService()
        loginItem.status = .enabled
        let model = Self.model(store: SettingsStore(storage: LoginItemStorage()), loginItem: loginItem)
        model.refreshLoginItemStatus()
        loginItem.unregisterError = FakeLoginItemService.Failure()

        model.setLoginItemEnabled(false)
        #expect(model.loginItemStatus == .enabled)
        #expect(model.loginItemOn)
        #expect(model.loginItemError == "Login item change failed.")
    }

    @Test func toggleCallsRegisterAndUnregister() {
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: SettingsStore(storage: LoginItemStorage()), loginItem: loginItem)
        model.refreshLoginItemStatus()

        model.setLoginItemEnabled(true)
        #expect(loginItem.registerCount == 1)
        #expect(model.loginItemOn)
        #expect(model.loginItemError == nil)

        model.setLoginItemEnabled(false)
        #expect(loginItem.unregisterCount == 1)
        #expect(!model.loginItemOn)
    }

    @Test func openLoginItemsCallsTheSystemSettings() {
        let loginItem = FakeLoginItemService()
        let model = Self.model(store: SettingsStore(storage: LoginItemStorage()), loginItem: loginItem)
        model.openLoginItemSettings()
        #expect(loginItem.openSystemSettingsCount == 1)
    }

    @Test func applicationsFolderDetection() throws {
        #expect(AppModel.isInApplications(bundleURL: Self.applicationsBundle))
        #expect(
            AppModel.isInApplications(
                bundleURL: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/MicBoost.app")))
        #expect(!AppModel.isInApplications(bundleURL: Self.downloadsBundle))

        // A bundle reached through a symlinked Applications folder counts as installed.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let linked = temporary.appendingPathComponent("Applications")
        try FileManager.default.createSymbolicLink(
            at: linked, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        #expect(AppModel.isInApplications(bundleURL: linked.appendingPathComponent("MicBoost.app")))
    }
}
