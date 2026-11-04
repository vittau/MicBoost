import CoreAudio
import Foundation
import MicBoostDSP
import Testing

@testable import MicBoostCore

/// Engine and settings of the manual test that lost the restore on quit: the maintainer's
/// microphone, the internal microphone used to diverge in System Settings, and the BlackHole.
private struct RestoreFixture {
    let fake = FakeAudioHardware()
    let storage = MemorySettingsStorage()
    let store: SettingsStore
    let controller: EngineController
    let source: AudioDevice
    let other: AudioDevice
    let blackHole: AudioDevice

    init(stored: Settings? = nil, defaultInput: AudioObjectID? = nil) throws {
        var source = device("fifine", "fifine Microphone")
        source.id = 3
        var other = device("internal", "Internal Microphone")
        other.id = 1
        var blackHole = device("BlackHole2ch_UID", "BlackHole 2ch", input: 2, output: 2)
        blackHole.id = 2
        self.source = source
        self.other = other
        self.blackHole = blackHole
        fake.deviceList = [other, blackHole, source]
        fake.input = defaultInput ?? source.id
        if let stored { try storage.seed(stored) }
        store = SettingsStore(storage: storage)
        controller = EngineController(hardware: fake, settings: store)
    }

    /// The `kAudioHardwarePropertyDefaultInputDevice` notification the HAL posts after an input
    /// change, delivered on the engine queue asynchronously.
    func emitDefaultInputChange() {
        fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice))
    }

    func waitForManaged(_ managed: Bool) async -> Bool {
        await waitUntil { await self.store.current.defaultInputManaged == managed }
    }

    /// The state a relaunch reads from disk.
    func persisted() async -> Settings { await SettingsStore(storage: storage).current }
}

/// "Use MicBoost" after a divergence saves the previous input and owns the default input, and
/// quitting afterwards restores it (docs/audio-engine.md "Política de entrada padrão").
@Test func quitAfterUseBlackHoleRestoresThePreviousInput() async throws {
    let fixture = try RestoreFixture()
    try await fixture.controller.start(inputUID: fixture.source.uid)
    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(await fixture.waitForManaged(true))

    // Divergence, then the panel action, twice, as in the manual test.
    for _ in 0..<2 {
        fixture.fake.input = fixture.other.id
        fixture.emitDefaultInputChange()
        #expect(await fixture.waitForManaged(false))
        try await fixture.controller.useBlackHole()
        #expect(fixture.fake.input == fixture.blackHole.id)

        // The recovery state is written immediately, before the HAL write.
        let persisted = await fixture.persisted()
        #expect(persisted.defaultInputManaged)
        #expect(persisted.previousDefaultInputUID == fixture.other.uid)
    }

    try await fixture.controller.stop()
    #expect(fixture.fake.input == fixture.other.id, "quitting did not restore the previous input")
    let stored = await fixture.store.current
    #expect(!stored.defaultInputManaged)
}

/// The divergence notification of the change the user is fixing can still be queued when the
/// panel action runs. Reading the old input then is not a user divergence: it must not release
/// the ownership the adoption just persisted, or the quit restores nothing.
@Test func pendingDivergenceNotificationDoesNotDropTheAdoption() async throws {
    let fixture = try RestoreFixture()
    try await fixture.controller.start(inputUID: fixture.source.uid)
    #expect(await fixture.waitForManaged(true))

    for _ in 0..<40 {
        fixture.fake.input = fixture.other.id
        fixture.emitDefaultInputChange()
        // No wait: the notification is still in flight when the action runs.
        try await fixture.controller.useBlackHole()

        let stored = await fixture.store.current
        #expect(stored.defaultInputManaged, "the adoption lost the ownership flag")
        #expect(stored.previousDefaultInputUID == fixture.other.uid)
        #expect(fixture.fake.input == fixture.blackHole.id)
    }

    try await fixture.controller.stop()
    #expect(fixture.fake.input == fixture.other.id, "quitting did not restore the previous input")
}

/// A relaunch after a force quit finds the BlackHole as default and the ownership persisted.
/// The start must keep that state, and the following voluntary stop must restore (docs/audio-engine.md
/// "Política de entrada padrão", recovery after a crash).
@Test func relaunchWithBlackHoleAlreadyDefaultKeepsThePersistedOwnership() async throws {
    let fixture = try RestoreFixture(
        stored: Settings(previousDefaultInputUID: "internal", defaultInputManaged: true),
        defaultInput: 2)
    try await fixture.controller.start(inputUID: fixture.source.uid)

    #expect(fixture.fake.writes.isEmpty, "an input that is already the BlackHole is not written again")
    let stored = await fixture.store.current
    #expect(stored.defaultInputManaged)
    #expect(stored.previousDefaultInputUID == "internal")

    try await fixture.controller.stop()
    #expect(fixture.fake.input == fixture.other.id)
}

/// Turning processing off is a voluntary stop too, and the engine keeps running across it.
@Test func stopAndRestartRestoresOncePerVoluntaryStop() async throws {
    let fixture = try RestoreFixture()
    try await fixture.controller.start(inputUID: fixture.source.uid)
    try await fixture.controller.stop()
    #expect(fixture.fake.input == fixture.source.id)

    try await fixture.controller.start(inputUID: fixture.source.uid)
    #expect(fixture.fake.input == fixture.blackHole.id)
    #expect(await fixture.waitForManaged(true))
    try await fixture.controller.stop()
    #expect(fixture.fake.input == fixture.source.id)
}
