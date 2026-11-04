import CoreAudio
import Foundation
import MicBoostDSP
import Testing

@testable import MicBoostCore

/// Hardware fake shared by the engine queue and the test task.
///
/// Every stored value is guarded by one lock, and the only work done while it is
/// held is a copy or a mutation; listeners are dispatched after unlocking. That is
/// the whole `@unchecked Sendable` justification.
final class FakeAudioHardware: AudioHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDevices: [AudioDevice] = []
    private var storedEmitDevicesOnAggregateCreation = false
    var emitDevicesOnAggregateCreation: Bool {
        get { lock.withLock { storedEmitDevicesOnAggregateCreation } }
        set { lock.withLock { storedEmitDevicesOnAggregateCreation = newValue } }
    }
    private var storedOutput: AudioObjectID = 0
    private var storedFailMonitorStart = false
    var output: AudioObjectID {
        get { lock.withLock { storedOutput } }
        set { lock.withLock { storedOutput = newValue } }
    }
    var failMonitorStart: Bool {
        get { lock.withLock { storedFailMonitorStart } }
        set { lock.withLock { storedFailMonitorStart = newValue } }
    }
    private var storedInput: AudioObjectID = 0
    private var registrations: [UUID: (HardwareProperty, DispatchQueue, @Sendable () -> Void)] = [:]
    private var storedFailure: EngineError?
    private var allowed = true
    private var creations = 0
    private var destructions = 0
    private var reads = 0
    private var starts = 0
    private var stops = 0
    private var storedWrites: [AudioObjectPropertySelector] = []
    private var rateWrites: [(uid: String, rate: Double)] = []
    private var storedMainSubDevice: String?
    private var storedSubDevices: [(uid: String, driftCompensation: Bool)] = []
    var engineEvents: FakeEngineEvents?

    var deviceList: [AudioDevice] {
        get { lock.withLock { storedDevices } }
        set { lock.withLock { storedDevices = newValue } }
    }

    var input: AudioObjectID {
        get { lock.withLock { storedInput } }
        set { lock.withLock { storedInput = newValue } }
    }

    var writes: [AudioObjectPropertySelector] { lock.withLock { storedWrites } }
    var listeners: [UUID: (HardwareProperty, DispatchQueue, @Sendable () -> Void)] {
        lock.withLock { registrations }
    }
    var aggregateCreations: Int { lock.withLock { creations } }
    var aggregateDestructions: Int { lock.withLock { destructions } }
    var deviceReads: Int { lock.withLock { reads } }
    var ioStarts: Int { lock.withLock { starts } }
    var ioStops: Int { lock.withLock { stops } }
    var appliedRateWrites: [(uid: String, rate: Double)] { lock.withLock { rateWrites } }
    /// Description of the last aggregate the engine asked for.
    var aggregateMainSubDevice: String? { lock.withLock { storedMainSubDevice } }
    var aggregateSubDevices: [(uid: String, driftCompensation: Bool)] { lock.withLock { storedSubDevices } }

    var microphoneAllowed: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }

    /// When set, `devices()` throws this instead of listing devices.
    var failure: EngineError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var aggregateID: AudioObjectID {
        lock.withLock { storedDevices.first { $0.uid == AggregateBuilder.uid }?.id ?? 0 }
    }

    func rate(of uid: String) -> Double? {
        lock.withLock { storedDevices.first { $0.uid == uid }?.sampleRate }
    }

    func device(_ uid: String) -> AudioDevice? {
        lock.withLock { storedDevices.first { $0.uid == uid } }
    }

    func update(_ uid: String, _ change: (inout AudioDevice) -> Void) {
        lock.withLock {
            guard let index = storedDevices.firstIndex(where: { $0.uid == uid }) else { return }
            change(&storedDevices[index])
        }
    }

    func devices() throws -> [AudioDevice] {
        let (list, failure) = lock.withLock { () -> ([AudioDevice], EngineError?) in
            reads += 1
            return (storedDevices, storedFailure)
        }
        if let failure { throw failure }
        return engineEvents?.devices(list) ?? list
    }

    func defaultOutput() throws -> AudioObjectID { output }

    func defaultInput() throws -> AudioObjectID { input }

    func setDefaultInput(_ device: AudioObjectID) throws {
        try writeDefault(kAudioHardwarePropertyDefaultInputDevice, device)
    }

    func writeDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) throws {
        guard
            selector != kAudioHardwarePropertyDefaultOutputDevice
                && selector != kAudioHardwarePropertyDefaultSystemOutputDevice
        else {
            Issue.record("Forbidden default output write")
            throw EngineError.invalidArgument("Default output write forbidden")
        }
        lock.withLock {
            storedWrites.append(selector)
            storedInput = device
        }
    }

    func addListener(
        _ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void
    ) throws -> UUID {
        let id = UUID()
        lock.withLock { registrations[id] = (property, queue, handler) }
        if property.selector == kAudioHardwarePropertyDevices {
            engineEvents?.register(queue: queue, handler: handler)
        }
        return id
    }

    func removeListener(_ token: UUID) throws { lock.withLock { registrations.removeValue(forKey: token) } }

    func emit(_ property: HardwareProperty) {
        let callbacks = lock.withLock {
            registrations.values.filter { $0.0 == property }.map { ($0.1, $0.2) }
        }
        for (queue, handler) in callbacks { queue.async(execute: handler) }
    }

    func listenerCount(_ property: HardwareProperty) -> Int {
        lock.withLock { registrations.values.filter { $0.0 == property }.count }
    }
}

extension FakeAudioHardware: EngineHardware {
    var microphoneAuthorized: Bool { microphoneAllowed }

    func maximumFrames(_ device: AudioObjectID, buffer: UInt32) throws -> UInt32 { buffer }
    func latencyFrames(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 { 0 }

    func layout(_ device: AudioObjectID) throws -> StreamLayout {
        guard let d = deviceList.first(where: { $0.id == device }) else { throw EngineError.formatUnsupported }
        return .init(
            inputs: d.inputChannels > 0 ? [d.inputChannels] : [],
            outputs: d.outputChannels > 0 ? [d.outputChannels] : [])
    }

    /// Writes the rate and notifies the rate listeners, as the HAL does.
    func setRate(_ device: AudioObjectID, rate: Double) throws {
        let uid = lock.withLock { () -> String? in
            guard let index = storedDevices.firstIndex(where: { $0.id == device }) else { return nil }
            storedDevices[index].sampleRate = rate
            rateWrites.append((storedDevices[index].uid, rate))
            return storedDevices[index].uid
        }
        guard uid != nil else { throw EngineError.formatUnsupported }
        emit(.init(device, kAudioDevicePropertyNominalSampleRate))
    }

    func createAggregate(source: String, destination: String, monitor: String?) throws -> AudioObjectID {
        let description = AggregateBuilder.description(source: source, destination: destination, monitor: monitor)
        let main = description[kAudioAggregateDeviceMainSubDeviceKey] as? String
        let subDevices = (description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []).map {
            (
                uid: $0[kAudioSubDeviceUIDKey] as? String ?? "",
                driftCompensation: ($0[kAudioSubDeviceDriftCompensationKey] as? Int ?? 0) != 0
            )
        }
        let id = lock.withLock {
            creations += 1
            storedMainSubDevice = main
            storedSubDevices = subDevices
            let id = AudioObjectID(900 + creations)
            var device = AudioDevice(id: id, uid: AggregateBuilder.uid, name: "Fake aggregate")
            device.inputChannels = 3
            device.outputChannels = 2
            device.subdeviceUIDs = [source, destination]
            storedDevices.append(device)
            return id
        }
        if emitDevicesOnAggregateCreation {
            emit(.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices))
        }
        return id
    }

    func destroyAggregate(_ device: AudioObjectID) throws {
        lock.withLock {
            destructions += 1
            storedDevices.removeAll { $0.id == device }
        }
    }

    func setBuffer(_ device: AudioObjectID, frames: UInt32) throws -> UInt32 { frames }

    func createIO(_ device: AudioObjectID, context: OpaquePointer) throws -> AudioDeviceIOProcID { mb_ioproc }

    func startIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {
        if failMonitorStart && aggregateSubDevices.count == 3 { throw EngineError.formatUnsupported }
        lock.withLock { starts += 1 }
    }

    func stopIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {
        lock.withLock { stops += 1 }
    }

    func destroyIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {}
    func streamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) throws {}
}

/// Only this event mailbox crosses queues; NSLock protects every stored value.
final class FakeEngineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var missing: Set<String> = []
    private var listener: (DispatchQueue, @Sendable () -> Void)?

    func devices(_ values: [AudioDevice]) -> [AudioDevice] {
        lock.withLock { values.filter { !missing.contains($0.uid) } }
    }

    func register(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        lock.withLock { listener = (queue, handler) }
    }

    /// Removes or restores a UID and notifies the device listener.
    func remove(_ uid: String, missing value: Bool) {
        let callback = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            if value { missing.insert(uid) } else { missing.remove(uid) }
            return listener
        }
        if let (queue, handler) = callback { queue.async(execute: handler) }
    }
}
