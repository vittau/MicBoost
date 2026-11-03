import CoreAudio
import Foundation
// All mutable state, including the hardware adapter, is confined to queue.
public final class DeviceService: @unchecked Sendable {
    public let queue: DispatchQueue
    private let hardware: any AudioHardware
    private var tokens: [UUID] = []
    private var pending: DispatchWorkItem?
    private let changed: @Sendable (Result<DeviceSnapshot, Error>) -> Void
    public init(hardware: any AudioHardware, queue: DispatchQueue, changed: @escaping @Sendable (Result<DeviceSnapshot, Error>) -> Void) {
        self.hardware = hardware; self.queue = queue; self.changed = changed
    }
    // Call start/stop/snapshot on queue; stop must precede releasing the service.
    public func snapshot() throws -> DeviceSnapshot {
        let devices = try hardware.devices(); let id = try hardware.defaultInput()
        return DeviceSnapshot(devices: devices, defaultInputUID: devices.first { $0.id == id }?.uid)
    }
    public func start() throws {
        try stop()
        do {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                tokens.append(try hardware.addListener(.init(AudioObjectID(kAudioObjectSystemObject), selector), queue: queue) { [weak self] in self?.schedule() })
            }
            try observeDevices(); changed(.success(try snapshot()))
        } catch { try? stop(); throw error }
    }
    private func observeDevices() throws {
        for token in tokens.dropFirst(2) { try hardware.removeListener(token) }
        tokens = Array(tokens.prefix(2))
        for device in try hardware.devices() {
            for property in [HardwareProperty(device.id, kAudioDevicePropertyDeviceIsAlive), .init(device.id, kAudioDevicePropertyNominalSampleRate), .init(device.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput), .init(device.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)] {
                tokens.append(try hardware.addListener(property, queue: queue) { [weak self] in self?.schedule() })
            }
        }
    }
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.observeDevices(); self.changed(.success(try self.snapshot())) } catch { self.changed(.failure(error)) }
        }
        pending = work; queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }
    public func stop() throws {
        pending?.cancel(); pending = nil
        var failure: Error?
        for token in tokens { do { try hardware.removeListener(token) } catch { failure = error } }
        tokens.removeAll(); if let failure { throw failure }
    }
}
public struct DeviceSnapshot: Codable, Sendable {
    public let devices: [AudioDevice]
    public let defaultInputUID: String?
    public var eligibleSources: [AudioDevice] { devices.filter { $0.isEligible(in: devices) } }
    public var blackHole: AudioDevice? { devices.first { $0.isBlackHole2ch } }
}
