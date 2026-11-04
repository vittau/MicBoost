import CoreAudio
import Foundation
import MicBoostDSP
import Testing

@testable import MicBoostCore

private func ranges(_ values: [Double]) -> [AudioRange] { values.map { AudioRange($0, $0) } }

@Test func workingRateSelection() {
    let all = ranges([8000, 16000, 24000, 44100, 48000, 96000])
    #expect(EngineController.workingSampleRate(source: ranges([44100, 48000]), destination: all) == 48000)
    // BlackHole does not offer 32 kHz, so the C920 bridge runs at 24 kHz.
    #expect(EngineController.workingSampleRate(source: ranges([16000, 24000, 32000]), destination: all) == 24000)
    #expect(
        EngineController.workingSampleRate(
            source: ranges([16000, 24000, 32000]), destination: ranges([16000, 24000, 32000])) == 32000)
    #expect(
        EngineController.workingSampleRate(source: ranges([88200, 96000]), destination: ranges([88200, 96000]))
            == 88200)
    #expect(EngineController.workingSampleRate(source: ranges([16000]), destination: ranges([44100])) == nil)
    #expect(
        EngineController.workingSampleRate(
            source: [AudioRange(44100, 96000)], destination: ranges([48000])) == 48000)
}

@Test func startPicksWorkingRateForBothDevices() async throws {
    let (fake, source, _) = recoveryFixture()
    let controller = await recoveryController(fake)
    try await controller.start(inputUID: source.uid)
    let status = await controller.status()
    #expect(status.state == .running)
    #expect(status.sampleRate == 24000)
    #expect(fake.rate(of: source.uid) == 24000)
    #expect(fake.rate(of: "BlackHole2ch_UID") == 24000)
    try await controller.stop()
}

@Test func voluntaryStopRestoresBothRates() async throws {
    let (fake, source, _) = recoveryFixture()
    let controller = await recoveryController(fake)
    try await controller.start(inputUID: source.uid)
    #expect(fake.rate(of: source.uid) == 24000)
    #expect(fake.rate(of: "BlackHole2ch_UID") == 24000)
    try await controller.stop()
    #expect(fake.rate(of: source.uid) == 32000)
    #expect(fake.rate(of: "BlackHole2ch_UID") == 48000)
}

@Test func sourceSwitchRestoresThePreviousSourceRate() async throws {
    let (fake, source, destination) = recoveryFixture()
    var second = AudioDevice(id: 3, uid: "second.source", name: "Second microphone")
    second.inputChannels = 1
    second.sampleRate = 48000
    second.availableSampleRates = ranges([48000])
    fake.deviceList = [source, destination, second]
    let controller = await recoveryController(fake)
    try await controller.start(inputUID: source.uid)
    #expect(fake.rate(of: source.uid) == 24000)
    try await controller.start(inputUID: second.uid)
    #expect(fake.rate(of: source.uid) == 32000)
    #expect(fake.rate(of: second.uid) == 48000)
    #expect(fake.rate(of: destination.uid) == 48000)
    try await controller.stop()
}

@Test func externalSourceRateChangeRecovers() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    await settle()
    fake.update(source.uid) { $0.sampleRate = 16000 }
    fake.emit(.init(source.id, kAudioDevicePropertyNominalSampleRate))
    #expect(await log.waitFor(.recovering(.formatChanged)))
    #expect(await waitUntil { await controller.status().state == .running })
    #expect(fake.rate(of: source.uid) == 24000)
    #expect(fake.aggregateCreations == 2)
    try await controller.stop()
}

@Test func externalBlackHoleRateChangeRecovers() async throws {
    let (fake, _, destination) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: "recovery.source")
    await settle()
    fake.update(destination.uid) { $0.sampleRate = 44100 }
    fake.emit(.init(destination.id, kAudioDevicePropertyNominalSampleRate))
    #expect(await log.waitFor(.recovering(.formatChanged)))
    #expect(await waitUntil { await controller.status().state == .running })
    #expect(fake.rate(of: destination.uid) == 24000)
    #expect(fake.aggregateCreations == 2)
    try await controller.stop()
}

@Test func blackHoleReturnClearsTheErrorByItself() async throws {
    let events = FakeEngineEvents()
    let (fake, source, destination) = recoveryFixture()
    fake.engineEvents = events
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    events.remove(destination.uid, missing: true)
    #expect(await waitUntil { await controller.status().state == .error(.blackHoleMissing) })
    events.remove(destination.uid, missing: false)
    #expect(await waitUntil { await controller.status().state == .running })
    #expect(log.states.contains(.error(.blackHoleMissing)))
    try await controller.stop()
}

@Test func permissionDeniedThenGranted() async throws {
    let (fake, source, _) = recoveryFixture()
    fake.microphoneAllowed = false
    let controller = await recoveryController(fake)
    await #expect(throws: EngineError.microphonePermissionDenied) {
        try await controller.start(inputUID: source.uid)
    }
    #expect(await controller.status().state == .error(.microphonePermissionDenied))
    fake.microphoneAllowed = true
    try await controller.start(inputUID: source.uid)
    #expect(await controller.status().state == .running)
    try await controller.stop()
}

@Test func sleepStopsAndWakeStartsOnce() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    try await controller.willSleep()
    #expect(await controller.status().state == .recovering(.sleep))
    #expect(fake.aggregateID == 0)
    #expect(fake.aggregateDestructions == 1)
    await controller.didWake()
    #expect(await waitUntil { await controller.status().state == .running })
    #expect(fake.aggregateCreations == 2)
    #expect(log.states.contains(.recovering(.sleep)))
    try await controller.stop()
}

@Test func wakeFailureFallsBackToRecovering() async throws {
    let (fake, source, _) = recoveryFixture()
    let controller = await recoveryController(fake)
    try await controller.start(inputUID: source.uid)
    try await controller.willSleep()
    fake.failure = .halFailure(-1, "Device enumeration")
    await controller.didWake()
    #expect(await waitUntil { await controller.status().state == .recovering(.wakeFailed) })
    fake.failure = nil
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices))
    #expect(await waitUntil { await controller.status().state == .running })
    #expect(fake.aggregateCreations == 2)
    try await controller.stop()
}

@Test func serviceRestartReEnumeratesByUID() async throws {
    let events = FakeEngineEvents()
    let (fake, source, destination) = recoveryFixture()
    fake.engineEvents = events
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    let staleAggregate = fake.aggregateID
    #expect(staleAggregate != 0)
    // coreaudiod restarted: every object ID is new and the private aggregate is gone.
    var movedSource = source
    movedSource.id = 11
    var movedDestination = destination
    movedDestination.id = 12
    fake.deviceList = [movedSource, movedDestination]
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted))
    #expect(await log.waitFor(.recovering(.serviceRestarted)))
    #expect(await waitUntil { await controller.status().state == .running })
    let status = await controller.status()
    #expect(status.source?.id == 11)
    #expect(status.blackHole?.id == 12)
    #expect(fake.aggregateCreations == 2)
    #expect(fake.ioStops == 0)
    #expect(fake.aggregateDestructions == 0)
    try await controller.stop()
}

@Test func overloadOnlyIncrementsTheCounter() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    let aggregate = fake.aggregateID
    fake.emit(.init(aggregate, kAudioDeviceProcessorOverload))
    #expect(await waitUntil { await controller.status().overloads == 1 })
    #expect(await controller.status().state == .running)
    #expect(fake.aggregateCreations == 1)
    #expect(!log.states.contains(.recovering(.formatChanged)))
    try await controller.stop()
}

@Test func ownRateWriteDoesNotTriggerRecovery() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    await settle()
    // A late notification for the rate MicBoost itself applied.
    fake.emit(.init(source.id, kAudioDevicePropertyNominalSampleRate))
    try await Task.sleep(for: .milliseconds(250))
    #expect(await controller.status().state == .running)
    #expect(fake.aggregateCreations == 1)
    #expect(!log.states.contains(.recovering(.formatChanged)))
    try await controller.stop()
}

@Test func externalChangeAfterStartIsNotRestored() async throws {
    let (fake, source, destination) = recoveryFixture()
    let controller = await recoveryController(fake)
    try await controller.start(inputUID: source.uid)
    // Another app moves the source after MicBoost set it, without a rebuild.
    fake.update(source.uid) { $0.sampleRate = 16000 }
    try await controller.stop()
    #expect(fake.rate(of: source.uid) == 16000)
    #expect(fake.rate(of: destination.uid) == 48000)
}

@Test func engineErrorDoesNotRestoreRates() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    await settle()
    fake.failure = .halFailure(-1, "Device enumeration")
    fake.emit(.init(source.id, kAudioDevicePropertyNominalSampleRate))
    #expect(await waitUntil { if case .error = await controller.status().state { true } else { false } })
    #expect(fake.rate(of: source.uid) == 24000)
    #expect(fake.rate(of: "BlackHole2ch_UID") == 24000)
    fake.failure = nil
    try await controller.stop()
}

@Test func deviceLatencyChangeDoesNotRebuild() async throws {
    let (fake, source, _) = recoveryFixture()
    let log = StateLog()
    let controller = await recoveryController(fake, log: log)
    try await controller.start(inputUID: source.uid)
    await settle()
    // While the aggregate runs, the HAL raises the source buffer range and offsets.
    fake.update(source.uid) {
        $0.bufferRange = .init(8, 4096)
        $0.inputLatency = 38
        $0.inputSafetyOffset = 38
    }
    fake.emit(.init(source.id, kAudioDevicePropertyDeviceIsAlive))
    try await Task.sleep(for: .milliseconds(250))
    #expect(await controller.status().state == .running)
    #expect(fake.aggregateCreations == 1)
    #expect(!log.states.contains(.recovering(.formatChanged)))
    try await controller.stop()
}
