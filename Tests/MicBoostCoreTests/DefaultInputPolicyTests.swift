import CoreAudio
import Foundation
import Testing

@testable import MicBoostCore

/// Device set and default input used by the policy tests. The BlackHole is the
/// 2-channel virtual device installed on the reference machine.
///
/// Every policy test is `@MainActor` so `DefaultInputManager` (not `Sendable`,
/// `nonisolated(nonsending)` methods) stays inside a single executor, as it does
/// on the engine queue in the app.
private struct PolicyFixture {
    let fake = FakeAudioHardware()
    let storage = MemorySettingsStorage()
    let store: SettingsStore
    let manager: DefaultInputManager
    let internalMic: AudioDevice
    let usbMic: AudioDevice
    let blackHole: AudioDevice

    /// IDs are explicit so each device is distinguishable by its `AudioObjectID`.
    init(defaultInput: AudioObjectID, stored: Settings? = nil) throws {
        var internalMic = device("internal", "Internal Microphone")
        internalMic.id = 1
        var usbMic = device("usb", "USB Interface")
        usbMic.id = 3
        var blackHole = device("BlackHole2ch_UID", "BlackHole 2ch", input: 2, output: 2)
        blackHole.id = 2
        self.internalMic = internalMic
        self.usbMic = usbMic
        self.blackHole = blackHole
        fake.deviceList = [internalMic, usbMic, blackHole]
        fake.input = defaultInput
        if let stored {
            try storage.seed(stored)
        }
        store = SettingsStore(storage: storage)
        manager = DefaultInputManager(hardware: fake, settings: store)
    }
}

@Test @MainActor func firstStartAdoptsBlackHoleAndSavesPreviousInput() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(fixture.fake.writes == [kAudioHardwarePropertyDefaultInputDevice])
    let stored = await fixture.store.current
    #expect(stored.previousDefaultInputUID == "internal")
    #expect(stored.defaultInputManaged)

    // A second store over the same storage is what a relaunch after a crash sees.
    let reloaded = SettingsStore(storage: fixture.storage)
    let persisted = await reloaded.current
    #expect(persisted.previousDefaultInputUID == "internal")
    #expect(persisted.defaultInputManaged)

    let status = fixture.manager.lastStatus
    #expect(status.isBlackHole)
    #expect(!status.divergedByUser)
    #expect(!status.unknown)
}

@Test @MainActor func blackHoleAlreadyDefaultKeepsPersistedRecoveryState() async throws {
    let stored = Settings(previousDefaultInputUID: "usb", defaultInputManaged: true)
    let fixture = try PolicyFixture(defaultInput: 2, stored: stored)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    #expect(fixture.fake.writes.isEmpty)
    var current = await fixture.store.current
    #expect(current.previousDefaultInputUID == "usb")
    #expect(current.defaultInputManaged)

    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.usbMic.id)
    #expect(fixture.fake.writes == [kAudioHardwarePropertyDefaultInputDevice])
    current = await fixture.store.current
    #expect(!current.defaultInputManaged)
}

@Test @MainActor func blackHoleAlreadyDefaultWithoutRecoveryStateStaysUnmanaged() async throws {
    let fixture = try PolicyFixture(defaultInput: 2)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    #expect(fixture.fake.writes.isEmpty)
    let current = await fixture.store.current
    #expect(current.previousDefaultInputUID == nil)
    #expect(!current.defaultInputManaged)

    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(fixture.fake.writes.isEmpty)
}

@Test @MainActor func userDivergenceThenUseBlackHole() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    // The user picks the internal microphone in System Settings while the engine runs.
    fixture.fake.input = fixture.internalMic.id
    let diverged = try await fixture.manager.defaultInputDidChange()
    #expect(!diverged.isBlackHole)
    #expect(diverged.divergedByUser)
    #expect(!diverged.unknown)
    #expect(fixture.fake.input == fixture.internalMic.id, "the policy must not revert the user")
    var current = await fixture.store.current
    #expect(!current.defaultInputManaged)
    #expect(fixture.fake.writes.count == 1)

    try await fixture.manager.useBlackHole()
    #expect(fixture.fake.input == fixture.blackHole.id)
    current = await fixture.store.current
    #expect(current.previousDefaultInputUID == "internal")
    #expect(current.defaultInputManaged)

    let adopted = try await fixture.manager.defaultInputDidChange()
    #expect(adopted.isBlackHole)
    #expect(!adopted.divergedByUser)
    #expect(!adopted.unknown)
}

@Test @MainActor func stopRestoresPreviousInput() async throws {
    let fixture = try PolicyFixture(defaultInput: 3)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)
    #expect(fixture.fake.input == fixture.blackHole.id)

    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.usbMic.id)
    #expect(
        fixture.fake.writes == [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultInputDevice])
    let current = await fixture.store.current
    #expect(!current.defaultInputManaged)
}

@Test @MainActor func stopDoesNotRestoreAfterUserChange() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    fixture.fake.input = fixture.usbMic.id
    try await fixture.manager.defaultInputDidChange()
    let writesBeforeStop = fixture.fake.writes.count

    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.usbMic.id)
    #expect(fixture.fake.writes.count == writesBeforeStop)
    let current = await fixture.store.current
    #expect(!current.defaultInputManaged)
}

@Test @MainActor func stopDoesNotRestoreWhenPreviousDeviceIsGone() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)

    fixture.fake.deviceList = [fixture.usbMic, fixture.blackHole]
    let writesBeforeStop = fixture.fake.writes.count
    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(fixture.fake.writes.count == writesBeforeStop)
    var current = await fixture.store.current
    #expect(!current.defaultInputManaged)

    // Same with the device still listed but not alive.
    let second = try PolicyFixture(defaultInput: 1)
    try await second.manager.engineDidStart(blackHole: second.blackHole)
    var dead = second.internalMic
    dead.alive = false
    second.fake.deviceList = [dead, second.usbMic, second.blackHole]
    try await second.manager.engineWillStop()
    #expect(second.fake.input == second.blackHole.id)
    current = await second.store.current
    #expect(!current.defaultInputManaged)
}

@Test @MainActor func engineErrorDoesNotRestore() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)
    #expect(fixture.fake.writes.count == 1)

    try await fixture.manager.engineWillStop(reason: .engineError)
    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(fixture.fake.writes.count == 1)
    var current = await fixture.store.current
    #expect(current.defaultInputManaged, "the engine still owns the input after a failure")

    // The later voluntary stop restores it.
    try await fixture.manager.engineWillStop()
    #expect(fixture.fake.input == fixture.internalMic.id)
    current = await fixture.store.current
    #expect(!current.defaultInputManaged)
}

@Test @MainActor func policyOnlyWritesDefaultInput() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    try await fixture.manager.engineDidStart(blackHole: fixture.blackHole)
    _ = try await fixture.manager.defaultInputDidChange()
    fixture.fake.input = fixture.usbMic.id
    _ = try await fixture.manager.defaultInputDidChange()
    try await fixture.manager.useBlackHole()
    try await fixture.manager.engineWillStop(reason: .engineError)
    try await fixture.manager.engineWillStop()

    #expect(fixture.fake.writes.allSatisfy { $0 == kAudioHardwarePropertyDefaultInputDevice })
}

@Test @MainActor func statusIsUnknownBeforeStart() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    let status = try await fixture.manager.defaultInputDidChange()
    #expect(status.unknown)
    #expect(!status.isBlackHole)
    #expect(!status.divergedByUser)
}

@Test @MainActor func useBlackHoleRequiresStart() async throws {
    let fixture = try PolicyFixture(defaultInput: 1)
    await #expect(throws: (any Error).self) { try await fixture.manager.useBlackHole() }
    #expect(fixture.fake.writes.isEmpty)
}
