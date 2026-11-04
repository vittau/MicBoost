import CoreAudio
import Dispatch
import Foundation
import Testing

@testable import MicBoostCore

/// Records whether each `AudioHardware` call ran on the engine queue.
///
/// The probe is only written on the engine queue and read through `TestEngine`,
/// which also runs there, so the plain fields need no lock.
private final class QueueProbe {
    let key = DispatchSpecificKey<Bool>()
    private(set) var calls = 0
    private(set) var offQueueCalls = 0

    func recordCall() {
        calls += 1
        if DispatchQueue.getSpecific(key: key) != true {
            offQueueCalls += 1
        }
    }
}

private final class QueueWatchingHardware: AudioHardware {
    let base: FakeAudioHardware
    let probe: QueueProbe

    init(base: FakeAudioHardware, probe: QueueProbe) {
        self.base = base
        self.probe = probe
    }

    func devices() throws -> [AudioDevice] {
        probe.recordCall()
        return try base.devices()
    }

    func defaultOutput() throws -> AudioObjectID { try base.defaultOutput() }
    func defaultInput() throws -> AudioObjectID {
        probe.recordCall()
        return try base.defaultInput()
    }

    func setDefaultInput(_ device: AudioObjectID) throws {
        probe.recordCall()
        try base.setDefaultInput(device)
    }

    func addListener(_ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws
        -> UUID
    {
        probe.recordCall()
        return try base.addListener(property, queue: queue, handler: handler)
    }

    func removeListener(_ token: UUID) throws {
        probe.recordCall()
        try base.removeListener(token)
    }
}

/// Stands in for `EngineController`: an actor whose executor is a serial queue,
/// the only place `DefaultInputManager` may run.
private actor TestEngine {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let manager: DefaultInputManager
    private let hardware: QueueWatchingHardware
    private let blackHole: AudioDevice

    init(storage: MemorySettingsStorage, defaultInput: AudioObjectID, blackHole: AudioDevice) {
        let queue = DispatchSerialQueue(label: "io.github.vittau.MicBoost.tests.engine")
        self.queue = queue
        let probe = QueueProbe()
        queue.setSpecific(key: probe.key, value: true)
        let base = FakeAudioHardware()
        let internalMic = device("internal", "Internal Microphone")
        var usbMic = device("usb", "USB Interface")
        usbMic.id = 3
        base.deviceList = [internalMic, usbMic, blackHole]
        base.input = defaultInput
        self.hardware = QueueWatchingHardware(base: base, probe: probe)
        self.blackHole = blackHole
        self.manager = DefaultInputManager(hardware: hardware, settings: SettingsStore(storage: storage))
    }

    func start() async throws { try await manager.engineDidStart(blackHole: blackHole) }

    func userChangesInput(to device: AudioDevice) { hardware.base.input = device.id }

    func defaultInputDidChange() async throws -> DefaultInputStatus { try await manager.defaultInputDidChange() }

    func useBlackHole() async throws { try await manager.useBlackHole() }

    func stop(_ reason: DefaultInputManager.StopReason) async throws {
        try await manager.engineWillStop(reason: reason)
    }

    var defaultInput: AudioObjectID { hardware.base.input }
    var writes: [AudioObjectPropertySelector] { hardware.base.writes }
    var halCalls: (total: Int, offQueue: Int) { (hardware.probe.calls, hardware.probe.offQueueCalls) }
}

/// The manager must run on its caller's executor, not on the cooperative pool.
@Test @MainActor func policyRunsOnTheEngineQueue() async throws {
    var blackHole = device("BlackHole2ch_UID", "BlackHole 2ch", input: 2, output: 2)
    blackHole.id = 2
    var usbMic = device("usb", "USB Interface")
    usbMic.id = 3
    let engine = TestEngine(storage: MemorySettingsStorage(), defaultInput: 1, blackHole: blackHole)

    try await engine.start()
    await engine.userChangesInput(to: usbMic)
    _ = try await engine.defaultInputDidChange()
    try await engine.useBlackHole()
    try await engine.stop(.engineError)
    try await engine.stop(.user)

    let calls = await engine.halCalls
    #expect(calls.total > 0)
    #expect(calls.offQueue == 0, "\(calls.offQueue) of \(calls.total) HAL calls ran off the engine queue")
    let writes = await engine.writes
    #expect(writes.allSatisfy { $0 == kAudioHardwarePropertyDefaultInputDevice })
}
