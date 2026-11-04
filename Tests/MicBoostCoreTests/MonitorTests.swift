import CoreAudio
import Foundation
import Testing

@testable import MicBoostCore

private func monitorHardware() -> FakeAudioHardware {
    let fake = FakeAudioHardware()
    var source = AudioDevice(id: 1, uid: "source", name: "Source")
    source.inputChannels = 1
    var destination = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole")
    destination.inputChannels = 2
    destination.outputChannels = 2
    var output = AudioDevice(id: 3, uid: "output", name: "Output")
    output.outputChannels = 2
    fake.deviceList = [source, destination, output]
    fake.output = 3
    return fake
}

@Test func independentMonitorKeepsAggregateAndRates() async throws {
    let fake = monitorHardware()
    fake.update("output") {
        $0.sampleRate = 44100
        $0.availableSampleRates = [.init(44100, 44100)]
    }
    let engine = EngineController(hardware: fake)
    try await engine.start(inputUID: "source")
    let starts = fake.ioStarts
    let aggregate = fake.aggregateID
    try await engine.setMonitorEnabled(true)
    guard case .active(let output, _, _) = await engine.status().monitor else {
        Issue.record("Monitor inactive")
        try await engine.stop()
        return
    }
    #expect(output.sampleRate == 44100)
    #expect(fake.aggregateID == aggregate)
    #expect(fake.aggregateSubDevices.count == 2)
    #expect(fake.ioStarts == starts)
    #expect(fake.monitorCounts.started == 1)
    try await engine.setMonitorEnabled(false)
    #expect(fake.aggregateID == aggregate)
    #expect(fake.rate(of: "output") == 44100)
    #expect(fake.monitorCounts.stopped == 1)
    #expect(!fake.appliedRateWrites.contains { $0.uid == "output" })
    try await engine.stop()
}
@Test func monitorFailureNeverRebuildsOrErrorsEngine() async throws {
    let fake = monitorHardware()
    fake.failMonitorStart = true
    let engine = EngineController(hardware: fake)
    try await engine.start(inputUID: "source")
    try await engine.setMonitorEnabled(true)
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .startFailed, outputName: "Output"))
    #expect(await engine.status().lastMonitorFailure?.error == .halFailure(-321, "Create monitor"))
    #expect(fake.aggregateCreations == 1)
    try await engine.stop()
}
@Test func monitorOutputChangesAndLossOnlyRebuildMonitor() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    fake.output = 2
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice))
    #expect(
        await waitUntil {
            await engine.status().monitor == .unavailable(reason: .outputIsLoopback, outputName: "BlackHole")
        })
    fake.output = 3
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice))
    #expect(await waitUntil { if case .active = await engine.status().monitor { true } else { false } })
    fake.deviceList.removeAll { $0.id == 3 }
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices))
    #expect(await waitUntil { await engine.status().monitor == .unavailable(reason: .noOutput, outputName: nil) })
    #expect(fake.aggregateCreations == 1)
    #expect(await engine.status().state == .running)
    try await engine.stop()
}
@Test(arguments: ["loopback", "noChannels", "failure"])
func unavailableMonitorDoesNotLoop(_ scenario: String) async throws {
    let fake = monitorHardware()
    fake.emitDevicesOnAggregateCreation = true
    if scenario == "loopback" { fake.output = 2 }
    if scenario == "noChannels" { fake.update("output") { $0.outputChannels = 0 } }
    if scenario == "failure" { fake.failMonitorStart = true }
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    try await Task.sleep(for: .milliseconds(350))
    #expect(fake.aggregateCreations == 1)
    #expect(await engine.status().state == .running)
    try await engine.stop()
}
@Test func stoppedMonitorIntentAndDuplexOutput() async throws {
    let fake = monitorHardware()
    fake.update("source") {
        $0.outputChannels = 1
        $0.transport = kAudioDeviceTransportTypeBluetooth
    }
    fake.output = 1
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    #expect(fake.aggregateCreations == 0)
    try await engine.start(inputUID: "source")
    guard case .active = await engine.status().monitor else {
        Issue.record("Duplex rejected")
        try await engine.stop()
        return
    }
    #expect(fake.aggregateSubDevices.count == 2)
    try await engine.willSleep()
    #expect(await engine.status().monitor == .off)
    try await engine.stop()
}

@Test func monitorRestartsAroundEngineRebuildAndWake() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake, wakeDelay: .milliseconds(10))
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    #expect(fake.monitorCounts.started == 1)
    try await engine.start(inputUID: "source", bufferFrames: 128)
    #expect(fake.monitorCounts.started == 2)
    #expect(fake.monitorCounts.stopped == 1)
    try await engine.willSleep()
    #expect(fake.monitorCounts.stopped == 2)
    await engine.didWake()
    #expect(await waitUntil { await engine.status().state == .running && fake.monitorCounts.started == 3 })
    try await engine.stop()
    #expect(fake.monitorCounts.stopped == 3)
}
@Test func outputFormatEventOnlyRecreatesMonitorAfterSettling() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    fake.emit(.init(3, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
    try await Task.sleep(for: .milliseconds(350))
    #expect(fake.monitorCounts.created == 1)
    fake.emit(.init(3, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
    #expect(await waitUntil { fake.monitorCounts.created == 2 })
    #expect(fake.aggregateCreations == 1)
    fake.update("output") { $0.sampleRate = 44100 }
    fake.emit(.init(3, kAudioDevicePropertyNominalSampleRate))
    #expect(await waitUntil { fake.monitorCounts.created == 3 })
    #expect(fake.aggregateCreations == 1)
    try await engine.stop()
}
@Test func monitorFormatFailureDoesNotChangeEngineState() async throws {
    let fake = monitorHardware()
    fake.monitorError = .formatUnsupported
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .formatUnsupported, outputName: "Output"))
    #expect(fake.aggregateCreations == 1)
    #expect(await engine.status().lastMonitorFailure?.error == .formatUnsupported)
    try await engine.stop()
}

@Test func monitorStopFailureRetainsContextWithoutStoppingBridgeRecovery() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    fake.failMonitorStop = true
    try await engine.setMonitorEnabled(false)
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .startFailed, outputName: "Output"))
    try await engine.start(inputUID: "source", bufferFrames: 128)
    #expect(await engine.status().state == .running)
    #expect(fake.aggregateCreations == 2)
    fake.failMonitorStop = false
    try await engine.stop()
    #expect(fake.monitorCounts.stopped == 1)
}
