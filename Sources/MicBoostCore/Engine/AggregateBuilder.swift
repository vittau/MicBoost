import AVFoundation
import CoreAudio
import Foundation
import MicBoostDSP

public struct StreamLayout: Sendable, Equatable {
    public var inputs: [UInt32]
    public var outputs: [UInt32]
    public var inputStreams: Int
    public var outputStreams: Int
    public init(inputs: [UInt32], outputs: [UInt32], inputStreams: Int? = nil, outputStreams: Int? = nil) {
        self.inputs = inputs
        self.outputs = outputs
        self.inputStreams = inputStreams ?? inputs.count
        self.outputStreams = outputStreams ?? outputs.count
    }
}
public protocol EngineHardware: AudioHardware {
    var microphoneAuthorized: Bool { get }
    func layout(_ device: AudioObjectID) throws -> StreamLayout
    func maximumFrames(_ device: AudioObjectID, buffer: UInt32) throws -> UInt32
    func latencyFrames(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32
    func setRate(_ device: AudioObjectID, rate: Double) throws
    func createAggregate(source: String, destination: String) throws -> AudioObjectID
    func destroyAggregate(_ device: AudioObjectID) throws
    func setBuffer(_ device: AudioObjectID, frames: UInt32) throws -> UInt32
    func createIO(_ device: AudioObjectID, context: OpaquePointer) throws -> AudioDeviceIOProcID
    func startIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws
    func stopIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws
    func destroyIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws
    func streamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) throws
}
public struct AggregateBuilder {
    public static let uid = "io.github.vittau.MicBoost.engine"
    public static func routing(source: StreamLayout, destination: StreamLayout) throws -> mb_routing {
        let count = source.inputs.reduce(0, +)
        guard count > 0, count <= 64, destination.outputs.reduce(0, +) == 2 else {
            throw EngineError.formatUnsupported
        }
        var result = mb_routing()
        result.input_count = count
        withUnsafeMutableBytes(of: &result.inputs) { bytes in
            let channels = bytes.bindMemory(to: mb_channel.self)
            var index = 0
            for (buffer, count) in source.inputs.enumerated() {
                for channel in 0..<count {
                    channels[index] = mb_channel(buffer: UInt32(buffer), channel: channel)
                    index += 1
                }
            }
        }
        withUnsafeMutableBytes(of: &result.outputs) { bytes in
            let channels = bytes.bindMemory(to: mb_channel.self)
            var index = 0
            for (buffer, count) in destination.outputs.enumerated() {
                for channel in 0..<count {
                    channels[index] = mb_channel(buffer: UInt32(source.outputs.count + buffer), channel: channel)
                    index += 1
                }
            }
        }
        return result
    }
}
extension CoreAudioHardware: EngineHardware {
    public var microphoneAuthorized: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status != .denied && status != .restricted
    }
    func write<T>(_ property: HardwareProperty, value: T) throws {
        var address = property.address
        var value = value
        try withUnsafeBytes(of: &value) { bytes in
            guard let base = bytes.baseAddress else { throw EngineError.formatUnsupported }
            try checkHAL(
                AudioObjectSetPropertyData(
                    property.object, &address, 0, nil,
                    UInt32(bytes.count), base), "Set property \(property.selector)")
        }
    }
    public func layout(_ device: AudioObjectID) throws -> StreamLayout {
        func buffers(_ scope: AudioObjectPropertyScope) throws -> [UInt32] {
            var address = HardwareProperty(device, kAudioDevicePropertyStreamConfiguration, scope).address
            var size: UInt32 = 0
            try checkHAL(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Layout size")
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
                alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            try checkHAL(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "Layout")
            return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(
                \.mNumberChannels)
        }
        return try StreamLayout(
            inputs: buffers(kAudioObjectPropertyScopeInput), outputs: buffers(kAudioObjectPropertyScopeOutput),
            inputStreams: values(
                .init(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), as: AudioStreamID.self
            ).count,
            outputStreams: values(
                .init(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), as: AudioStreamID.self
            ).count)
    }
    public func maximumFrames(_ device: AudioObjectID, buffer: UInt32) throws -> UInt32 {
        var address = HardwareProperty(device, kAudioDevicePropertyUsesVariableBufferFrameSizes).address
        guard AudioObjectHasProperty(device, &address) else { return buffer }
        return max(buffer, try scalar(.init(device, kAudioDevicePropertyUsesVariableBufferFrameSizes), as: UInt32.self))
    }
    public func latencyFrames(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        let latency = try scalar(.init(device, kAudioDevicePropertyLatency, scope), as: UInt32.self)
        let safety = try scalar(.init(device, kAudioDevicePropertySafetyOffset, scope), as: UInt32.self)
        let streams = try values(.init(device, kAudioDevicePropertyStreams, scope), as: AudioStreamID.self)
        let streamLatency =
            try streams.map { try scalar(.init($0, kAudioStreamPropertyLatency), as: UInt32.self) }.max() ?? 0
        return latency + safety + streamLatency
    }
    public func setRate(_ device: AudioObjectID, rate: Double) throws {
        try write(.init(device, kAudioDevicePropertyNominalSampleRate), value: rate)
    }
    public func createAggregate(source: String, destination: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MicBoost Engine", kAudioAggregateDeviceUIDKey: AggregateBuilder.uid,
            kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: source,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: source],
                [kAudioSubDeviceUIDKey: destination, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var id: AudioObjectID = 0
        try checkHAL(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Create aggregate")
        return id
    }
    public func destroyAggregate(_ device: AudioObjectID) throws {
        try checkHAL(AudioHardwareDestroyAggregateDevice(device), "Destroy aggregate")
    }
    public func setBuffer(_ device: AudioObjectID, frames: UInt32) throws -> UInt32 {
        let range = try scalar(.init(device, kAudioDevicePropertyBufferFrameSizeRange), as: AudioValueRange.self)
        let value = UInt32(max(range.mMinimum, min(range.mMaximum, Double(frames))))
        try write(.init(device, kAudioDevicePropertyBufferFrameSize), value: value)
        return try scalar(.init(device, kAudioDevicePropertyBufferFrameSize), as: UInt32.self)
    }
    public func createIO(_ device: AudioObjectID, context: OpaquePointer) throws -> AudioDeviceIOProcID {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            for stream in try values(.init(device, kAudioDevicePropertyStreams, scope), as: AudioStreamID.self) {
                var format = try scalar(
                    .init(stream, kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)
                func supported(_ f: AudioStreamBasicDescription) -> Bool {
                    f.mFormatID == kAudioFormatLinearPCM && f.mBitsPerChannel == 32
                        && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
                        && f.mFormatFlags & kAudioFormatFlagIsPacked != 0
                        && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
                        && f.mBytesPerFrame == 4
                            * (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : f.mChannelsPerFrame)
                }
                if !supported(format) {
                    format.mFormatID = kAudioFormatLinearPCM
                    format.mFormatFlags =
                        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                        | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                    format.mBitsPerChannel = 32
                    format.mFramesPerPacket = 1
                    format.mBytesPerFrame =
                        4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame)
                    format.mBytesPerPacket = format.mBytesPerFrame
                    do { try write(.init(stream, kAudioStreamPropertyVirtualFormat), value: format) } catch {
                        throw EngineError.formatUnsupported
                    }
                    let actual = try scalar(
                        .init(stream, kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)
                    guard supported(actual), actual.mSampleRate == format.mSampleRate else {
                        throw EngineError.formatUnsupported
                    }
                }
            }
        }
        var proc: AudioDeviceIOProcID?
        try checkHAL(
            AudioDeviceCreateIOProcID(device, mb_ioproc, UnsafeMutableRawPointer(context), &proc),
            "Create engine IOProc")
        guard let proc else { throw EngineError.formatUnsupported }
        return proc
    }
    public func startIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {
        try checkHAL(AudioDeviceStart(device, proc), "Start engine")
    }
    public func stopIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {
        try checkHAL(AudioDeviceStop(device, proc), "Stop engine")
    }
    public func destroyIO(_ device: AudioObjectID, proc: AudioDeviceIOProcID) throws {
        try checkHAL(AudioDeviceDestroyIOProcID(device, proc), "Destroy engine IOProc")
    }
    public func streamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) throws {
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, enabled.count - 1) * 4
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(enabled.count)
        withUnsafeMutablePointer(to: &usage.pointee.mStreamIsOn) { first in
            first.withMemoryRebound(to: UInt32.self, capacity: enabled.count) { values in
                for (i, on) in enabled.enumerated() { values[i] = on ? 1 : 0 }
            }
        }
        var address = HardwareProperty(
            device, kAudioDevicePropertyIOProcStreamUsage,
            input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        ).address
        try checkHAL(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw), "Set IOProc stream usage")
    }
}
