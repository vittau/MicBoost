import Foundation
import Testing

@testable import MicBoostCore

/// Polls a condition that depends on the engine queue.
func waitUntil(
    timeout: Duration = .milliseconds(1500), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Waits past the engine's settling window, so a format notification counts as external.
func settle() async { try? await Task.sleep(for: .milliseconds(340)) }

/// Records the states delivered on the engine queue.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineState] = []

    func append(_ state: EngineState) { lock.withLock { values.append(state) } }

    var states: [EngineState] { lock.withLock { values } }

    func waitFor(_ state: EngineState, timeout: Duration = .milliseconds(1500)) async -> Bool {
        await waitUntil(timeout: timeout) { self.states.contains(state) }
    }
}

/// Source at a low nominal rate plus BlackHole's real rate list, which has no 32 kHz, so the
/// working rate is 24 kHz.
func recoveryFixture() -> (FakeAudioHardware, AudioDevice, AudioDevice) {
    var source = AudioDevice(id: 1, uid: "recovery.source", name: "USB Microphone")
    source.inputChannels = 2
    source.sampleRate = 32000
    source.availableSampleRates = [16000, 24000, 32000].map { AudioRange($0, $0) }
    var destination = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole")
    destination.inputChannels = 2
    destination.outputChannels = 2
    destination.sampleRate = 48000
    destination.availableSampleRates = [8000, 16000, 24000, 44100, 48000, 96000].map { AudioRange($0, $0) }
    let fake = FakeAudioHardware()
    fake.deviceList = [source, destination]
    return (fake, source, destination)
}

func recoveryController(_ fake: FakeAudioHardware, log: StateLog? = nil) async -> EngineController {
    let controller = EngineController(
        hardware: fake, settings: SettingsStore(storage: MemorySettingsStorage()), wakeDelay: .milliseconds(40))
    if let log { await controller.observe { log.append($0) } }
    return controller
}
