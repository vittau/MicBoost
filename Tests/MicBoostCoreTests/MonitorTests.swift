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
@Test func monitorLifecycleAndClock() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake)
    try await engine.start(inputUID: "source")
    #expect(await engine.status().monitor == .off)
    try await engine.setMonitorEnabled(true)
    #expect(fake.aggregateSubDevices.map(\.uid) == ["source", "BlackHole2ch_UID", "output"])
    #expect(fake.aggregateSubDevices.map(\.driftCompensation) == [true, false, true])
    #expect(fake.aggregateMainSubDevice == "BlackHole2ch_UID")
    guard case .active(let output, let latency) = await engine.status().monitor else {
        Issue.record("Monitor inactive")
        try await engine.stop()
        return
    }
    #expect(output.id == 3)
    #expect(abs(latency - 512.0 / 48) < 0.001)
    try await engine.setMonitorEnabled(false)
    #expect(await engine.status().monitor == .off)
    #expect(fake.aggregateSubDevices.count == 2)
    try await engine.stop()
    #expect(!fake.writes.contains(kAudioHardwarePropertyDefaultOutputDevice))
    #expect(!fake.writes.contains(kAudioHardwarePropertyDefaultSystemOutputDevice))
}
@Test func monitorRejectsLoopbackAndMissingOutput() async throws {
    for id: AudioObjectID in [0, 2] {
        let fake = monitorHardware()
        fake.output = id
        let engine = EngineController(hardware: fake)
        try await engine.setMonitorEnabled(true)
        try await engine.start(inputUID: "source")
        #expect(await engine.status().state == .running)
        #expect(
            await engine.status().monitor
                == .unavailable(
                    reason: id == 0 ? .noOutput : .outputIsLoopback, outputName: id == 0 ? nil : "BlackHole"))
        #expect(fake.aggregateSubDevices.count == 2)
        try await engine.stop()
    }
}
@Test func monitorStartFailureFallsBack() async throws {
    let fake = monitorHardware()
    fake.failMonitorStart = true
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .formatUnsupported, outputName: "Output"))
    #expect(fake.aggregateCreations == 2)
    try await engine.stop()
}
@Test func monitorMapsMonoSplitAndSourceOutputs() throws {
    for (outputs, same, offset) in [([UInt32(1)], false, UInt32(2)), ([1, 1], false, 2), ([2], true, 0)] {
        let routing = try AggregateBuilder.routing(
            source: .init(inputs: [1], outputs: [2]), destination: .init(inputs: [2], outputs: [2]),
            monitor: .init(inputs: [], outputs: outputs), monitorIsSource: same)
        #expect(routing.monitor_count == min(2, outputs.reduce(0, +)))
        #expect(routing.monitor.0.buffer == offset)
    }
}

@Test func monitorRebuildsOnOutputChangeAndLoss() async throws {
    let fake = monitorHardware()
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    try await Task.sleep(for: .milliseconds(320))
    fake.output = 2
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice))
    try await Task.sleep(for: .milliseconds(180))
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .outputIsLoopback, outputName: "BlackHole"))
    fake.output = 3
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice))
    try await Task.sleep(for: .milliseconds(180))
    guard case .active = await engine.status().monitor else {
        Issue.record("Monitor did not recover")
        try await engine.stop()
        return
    }
    fake.deviceList.removeAll { $0.id == 3 }
    fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices))
    try await Task.sleep(for: .milliseconds(180))
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .noOutput, outputName: nil))
    try await engine.stop()
}
@Test func monitorReusesSourceAndRejectsDisjointRates() async throws {
    let fake = monitorHardware()
    fake.update("source") { $0.outputChannels = 1 }
    fake.output = 1
    let engine = EngineController(hardware: fake)
    try await engine.setMonitorEnabled(true)
    try await engine.start(inputUID: "source")
    #expect(fake.aggregateSubDevices.count == 2)
    guard case .active = await engine.status().monitor else {
        Issue.record("Duplex source unavailable")
        try await engine.stop()
        return
    }
    try await engine.stop()
    fake.output = 3
    fake.update("output") { $0.availableSampleRates = [.init(96000, 96000)] }
    try await engine.start(inputUID: "source")
    #expect(await engine.status().state == .running)
    #expect(await engine.status().monitor == .unavailable(reason: .formatUnsupported, outputName: "Output"))
    try await engine.stop()
}

@Test func reportedMonitorLatencyCountsEachDeviceStreamAndBufferOnce() {
    let input = HardwareLatency(device: 26, safety: 48, stream: 1439)
    let output = HardwareLatency(device: 69, safety: 48, stream: 425)
    let latency = EngineController.reportedMonitorLatency(
        inputFrames: input.total, outputFrames: output.total, bufferFrames: 256, sampleRate: 48000)
    #expect(abs(latency - 53.4791666667) < 0.000001)
    let withoutStreams = EngineController.reportedMonitorLatency(
        inputFrames: 74, outputFrames: 117, bufferFrames: 256, sampleRate: 48000)
    #expect(abs(withoutStreams - 14.6458333333) < 0.000001)
    #expect(abs((latency - withoutStreams) - Double(1439 + 425) / 48) < 0.000001)
}

@Test func silentMonitorPhysicalEstimateIncludesInputBridgeAndOutput() {
    let output = HardwareLatency(device: 69, safety: 48, stream: 425)
    let input = HardwareLatency(device: 26, safety: 48, stream: 1439)
    let sum = LatencyMeasurement.monitorPhysicalMilliseconds(
        sourceToBlackHole: 13.1875, input: input, output: output, sampleRate: 48000)
    #expect(abs(sum - 56.0) < 0.000001)
    let zeroInput = LatencyMeasurement.monitorPhysicalMilliseconds(
        sourceToBlackHole: 13.1875, input: .init(device: 0, safety: 0, stream: 0), output: output, sampleRate: 48000)
    #expect(abs((sum - zeroInput) - Double(input.total) / 48) < 0.000001)
}
