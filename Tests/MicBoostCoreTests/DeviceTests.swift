import CoreAudio
import Dispatch
import Foundation
import Testing
@testable import MicBoostCore
func device(_ uid: String, _ name: String = "Input", input: UInt32 = 1, output: UInt32 = 0) -> AudioDevice {
    var d = AudioDevice(id: 1, uid: uid, name: name); d.inputChannels = input; d.outputChannels = output; return d
}
@Test func eligibility() throws {
    let source = device("source")
    let bh = device("BlackHole16ch_UID", "BlackHole 16ch")
    let own = device("io.github.vittau.MicBoost.engine")
    var aggregate = device("aggregate"); aggregate.subdeviceUIDs = [bh.uid]
    let output = device("output", input: 0, output: 2)
    let all = [source, bh, own, aggregate, output]
    let fake = FakeAudioHardware(); fake.deviceList = all
    let service = DeviceService(hardware: fake, queue: .init(label: "eligibility")) { _ in }
    #expect(try service.snapshot().eligibleSources == [source])
    #expect(!device("custom", "BlackHole 64ch").isEligible(in: []))
}
@Test func detection() throws {
    #expect(device("BlackHole2ch_UID").isBlackHole2ch)
    var fallback = device("custom", "Custom BlackHole", output: 2); fallback.manufacturer = "Existential Audio Inc."
    #expect(fallback.isBlackHole2ch)
    let fake = FakeAudioHardware(); fake.deviceList = [fallback]
    let service = DeviceService(hardware: fake, queue: .init(label: "detection")) { _ in }
    #expect(try service.snapshot().blackHole == fallback)
    fallback.outputChannels = 16; #expect(!fallback.isBlackHole2ch)
    fallback.outputChannels = 2; fallback.manufacturer = "Other"; #expect(!fallback.isBlackHole2ch)
}
@Test func defaultOutputGuard() throws {
    let fake = FakeAudioHardware(); fake.deviceList = [device("source")]; fake.input = 1
    let service = DeviceService(hardware: fake, queue: .init(label: "guard")) { _ in }
    try service.start(); #expect(try service.snapshot().defaultInputUID == "source"); try service.stop()
    #expect(fake.writes.isEmpty)
    #expect(fake.listeners.isEmpty)
}
// Test state is read and written only on the service queue.
private final class Counter: @unchecked Sendable { var count = 0 }
@Test func coalescing() async throws {
    let queue = DispatchQueue(label: "test.devices"); let fake = FakeAudioHardware(); let counter = Counter()
    let service = DeviceService(hardware: fake, queue: queue) { _ in counter.count += 1 }
    try queue.sync { try service.start()
        for _ in 0..<20 { fake.emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)) }
    }
    try await Task.sleep(for: .milliseconds(60))
    queue.sync { #expect(counter.count == 1) }
    try await Task.sleep(for: .milliseconds(160))
    try queue.sync { #expect(counter.count == 2); try service.stop(); #expect(fake.listeners.isEmpty) }
}
@Test func fakeRejectsOutputWrite() async {
    await withKnownIssue("Fake must fail the test on a forbidden output write") {
        let fake = FakeAudioHardware()
        #expect(throws: EngineError.self) { try fake.writeDefault(kAudioHardwarePropertyDefaultOutputDevice, 1) }
        #expect(fake.writes.isEmpty)
    }
}
