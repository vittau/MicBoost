import CoreAudio
import Foundation
import Testing

@testable import MicBoostCore

final class FakeAudioHardware: AudioHardware {
    var deviceList: [AudioDevice] = []
    var input: AudioObjectID = 0
    var writes: [AudioObjectPropertySelector] = []
    var listeners: [UUID: (HardwareProperty, DispatchQueue, @Sendable () -> Void)] = [:]
    func devices() throws -> [AudioDevice] { deviceList }
    func defaultInput() throws -> AudioObjectID { input }
    func setDefaultInput(_ device: AudioObjectID) throws {
        try writeDefault(kAudioHardwarePropertyDefaultInputDevice, device)
    }
    func writeDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) throws {
        guard selector != kAudioHardwarePropertyDefaultOutputDevice else {
            Issue.record("Forbidden default output write")
            throw EngineError.invalidArgument("Default output write forbidden")
        }
        writes.append(selector)
        input = device
    }
    func addListener(_ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws
        -> UUID
    {
        let id = UUID()
        listeners[id] = (property, queue, handler)
        return id
    }
    func removeListener(_ token: UUID) throws { listeners.removeValue(forKey: token) }
    func emit(_ property: HardwareProperty) {
        for (_, (p, queue, handler)) in listeners where p == property { queue.async(execute: handler) }
    }
}
