import CoreAudio
import Foundation

public final class CoreAudioHardware: AudioHardware {
    private var listeners: [UUID: (HardwareProperty, DispatchQueue, AudioObjectPropertyListenerBlock)] = [:]
    public init() {}
    func values<T>(_ property: HardwareProperty, as: T.Type) throws -> [T] {
        var address = property.address
        var size: UInt32 = 0
        try checkHAL(
            AudioObjectGetPropertyDataSize(property.object, &address, 0, nil, &size),
            "Property size \(property.selector)")
        guard size > 0 else { return [] }
        guard Int(size) % MemoryLayout<T>.stride == 0 else { throw EngineError.formatUnsupported }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try checkHAL(
            AudioObjectGetPropertyData(property.object, &address, 0, nil, &size, pointer),
            "Read property \(property.selector)")
        return Array(
            UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
    }
    func scalar<T>(_ property: HardwareProperty, as: T.Type) throws -> T {
        guard let value = try values(property, as: T.self).first else { throw EngineError.formatUnsupported }
        return value
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = HardwareProperty(id, selector).address
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: result))
        try checkHAL(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result), "Read string \(selector)")
        guard let result else { throw EngineError.formatUnsupported }
        return result.takeUnretainedValue() as String
    }
    private func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> UInt32 {
        var address = HardwareProperty(id, kAudioDevicePropertyStreamConfiguration, scope).address
        var size: UInt32 = 0
        try checkHAL(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Stream configuration size")
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        try checkHAL(AudioObjectGetPropertyData(id, &address, 0, nil, &size, data), "Read stream configuration")
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) {
            $0 + $1.mNumberChannels
        }
    }
    public func devices() throws -> [AudioDevice] {
        try values(
            .init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices), as: AudioObjectID.self
        ).map { id in
            var d = AudioDevice(
                id: id, uid: try string(id, kAudioDevicePropertyDeviceUID),
                name: try string(id, kAudioObjectPropertyName))
            d.manufacturer = try string(id, kAudioObjectPropertyManufacturer)
            d.transport = try scalar(.init(id, kAudioDevicePropertyTransportType), as: UInt32.self)
            d.inputChannels = try channels(id, kAudioObjectPropertyScopeInput)
            d.outputChannels = try channels(id, kAudioObjectPropertyScopeOutput)
            d.sampleRate = try scalar(.init(id, kAudioDevicePropertyNominalSampleRate), as: Double.self)
            d.availableSampleRates = try values(
                .init(id, kAudioDevicePropertyAvailableNominalSampleRates), as: AudioValueRange.self
            ).map { .init($0.mMinimum, $0.mMaximum) }
            let range = try scalar(.init(id, kAudioDevicePropertyBufferFrameSizeRange), as: AudioValueRange.self)
            d.bufferRange = .init(range.mMinimum, range.mMaximum)
            d.alive = try scalar(.init(id, kAudioDevicePropertyDeviceIsAlive), as: UInt32.self) != 0
            if d.inputChannels > 0 {
                d.inputLatency = try scalar(
                    .init(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput), as: UInt32.self)
                d.inputSafetyOffset = try scalar(
                    .init(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput), as: UInt32.self)
            }
            if d.outputChannels > 0 {
                d.outputLatency = try scalar(
                    .init(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), as: UInt32.self)
                d.outputSafetyOffset = try scalar(
                    .init(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), as: UInt32.self)
            }
            if d.transport == kAudioDeviceTransportTypeAggregate {
                var address = HardwareProperty(id, kAudioAggregateDevicePropertyFullSubDeviceList).address
                var list: Unmanaged<CFArray>?
                var size = UInt32(MemoryLayout.size(ofValue: list))
                try checkHAL(
                    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list), "Read aggregate subdevice UIDs")
                guard let list, let uids = list.takeUnretainedValue() as? [String] else {
                    throw EngineError.formatUnsupported
                }
                d.subdeviceUIDs = uids
            }
            return d
        }
    }
    public func defaultInput() throws -> AudioObjectID {
        try scalar(
            .init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            as: AudioObjectID.self)
    }
    public func setDefaultInput(_ device: AudioObjectID) throws {
        var address = HardwareProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice
        ).address
        var device = device
        try checkHAL(
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: device)),
                &device), "Set default input")
    }
    public func addListener(_ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void)
        throws -> UUID
    {
        var address = property.address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let token = UUID()
        try checkHAL(AudioObjectAddPropertyListenerBlock(property.object, &address, queue, block), "Add listener")
        listeners[token] = (property, queue, block)
        return token
    }
    public func removeListener(_ token: UUID) throws {
        guard let (property, queue, block) = listeners[token] else { return }
        var address = property.address
        let status = AudioObjectRemovePropertyListenerBlock(property.object, &address, queue, block)
        // A coreaudiod restart invalidates the object and its registered listener together.
        if status != kAudioHardwareBadObjectError { try checkHAL(status, "Remove listener") }
        listeners.removeValue(forKey: token)
    }
}
