import CoreAudio
import Foundation
import MicBoostDSP
import Testing

@testable import MicBoostCore

@Test func streamChannelMaps() throws {
    for count: UInt32 in [1, 2, 8] {
        for buffers in [[count], Array(repeating: UInt32(1), count: Int(count))] {
            let map = try AggregateBuilder.routing(
                source: .init(inputs: buffers, outputs: [2]),
                destination: .init(inputs: [2], outputs: [2]))
            #expect(map.input_count == count)
            #expect(map.outputs.0.buffer == 1)
            #expect(map.outputs.0.channel == 0)
            #expect(map.outputs.1.buffer == 1)
            #expect(map.outputs.1.channel == 1)
        }
    }
    let split = try AggregateBuilder.routing(
        source: .init(inputs: [8], outputs: []),
        destination: .init(inputs: [1, 1], outputs: [1, 1]))
    #expect(split.outputs.1.buffer == 1)
    #expect(split.outputs.1.channel == 0)
}

@Test func missingBlackHoleState() async throws {
    let controller = EngineController(hardware: FakeAudioHardware())
    try await controller.start(inputUID: "source")
    #expect(await controller.status().state == .error(.blackHoleMissing))
    try await controller.stop()
    #expect(await controller.status().state == .stopped)
}

@Test func sourceLossState() async throws {
    let fake = FakeAudioHardware()
    var destination = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole")
    destination.outputChannels = 2
    fake.deviceList = [destination]
    let controller = EngineController(hardware: fake)
    try await controller.start(inputUID: "missing")
    #expect(await controller.status().state == .error(.sourceUnavailable("missing")))
    try await controller.stop()
}

@Test func runningEngineRecoversSameSourceAndBlackHole() async throws {
    let events = FakeEngineEvents()
    let fake = FakeAudioHardware()
    fake.engineEvents = events
    var source = AudioDevice(id: 1, uid: "test.source", name: "Source")
    source.inputChannels = 1
    var destination = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole")
    destination.inputChannels = 2
    destination.outputChannels = 2
    fake.deviceList = [source, destination]
    let controller = EngineController(hardware: fake)
    try await controller.start(inputUID: source.uid)
    #expect(await controller.status().state == .running)
    events.remove(source.uid, missing: true)
    #expect(await waitUntil { await controller.status().state == .recovering(.sourceLost) })
    events.remove(source.uid, missing: false)
    #expect(await waitUntil { await controller.status().state == .running })
    events.remove(destination.uid, missing: true)
    #expect(await waitUntil { await controller.status().state == .error(.blackHoleMissing) })
    events.remove(destination.uid, missing: false)
    #expect(await waitUntil { await controller.status().state == .running })
    try await controller.stop()
    #expect(await controller.status().state == .stopped)
}
