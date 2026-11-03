import CoreAudio
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

extension FakeAudioHardware: EngineHardware {
    func layout(_ device: AudioObjectID) throws -> StreamLayout {
        guard let d = deviceList.first(where: { $0.id == device }) else { throw EngineError.formatUnsupported }
        return .init(
            inputs: d.inputChannels > 0 ? [d.inputChannels] : [],
            outputs: d.outputChannels > 0 ? [d.outputChannels] : [])
    }
    func setRate(_ device: AudioObjectID, rate: Double) throws {
        guard let index = deviceList.firstIndex(where: { $0.id == device }) else { throw EngineError.formatUnsupported }
        deviceList[index].sampleRate = rate
    }
    func createAggregate(source: String, destination: String) throws -> AudioObjectID {
        var device = AudioDevice(id: 999, uid: AggregateBuilder.uid, name: "Fake aggregate")
        device.inputChannels = 3
        device.outputChannels = 2
        deviceList.append(device)
        return device.id
    }
    func destroyAggregate(_ device: AudioObjectID) throws { deviceList.removeAll { $0.id == device } }
    func setBuffer(_ device: AudioObjectID, frames: UInt32) throws -> UInt32 { frames }
    func createIO(_ device: AudioObjectID, context: OpaquePointer) throws -> AudioDeviceIOProcID { mb_ioproc }
    func startIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {}
    func stopIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {}
    func destroyIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {}
    func streamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) throws {}
}
@Test func missingBlackHoleState() async throws {
    let controller = EngineController(hardware: FakeAudioHardware())
    try await controller.start(inputUID: "source")
    #expect(await controller.status().state == .error("blackHoleMissing"))
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
    #expect(await controller.status().state == .recovering("sourceLost"))
    try await controller.stop()
}
