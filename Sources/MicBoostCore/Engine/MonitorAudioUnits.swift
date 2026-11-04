import AudioToolbox
import CoreAudio
import Foundation
import MicBoostDSP

public protocol MonitorSession: AnyObject {
    var latencySeconds: Double { get }
    var outputBufferFrames: UInt32 { get }
    func start() throws
    func setCorrection(_ correction: Double) throws
    func stop() throws
}

/// Owns units on the engine queue; all callbacks and sample access stay in C.
final class MonitorAudioUnits: MonitorSession {
    private var output: AudioUnit?
    private var speed: AudioUnit?
    private var started = false
    let outputBufferFrames: UInt32
    private(set) var latencySeconds = 0.0

    init(
        context: OpaquePointer, rate: Double, channels: UInt32, device: AudioObjectID?,
        outputRate: Double, buffer: UInt32, physicalChannels: UInt32? = nil
    ) throws {
        outputBufferFrames = buffer
        do {
            speed = try Self.unit(kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed)
            output = try Self.unit(
                device == nil ? kAudioUnitType_FormatConverter : kAudioUnitType_Output,
                device == nil ? kAudioUnitSubType_AUConverter : kAudioUnitSubType_HALOutput)
            guard let output, let speed else { throw EngineError.formatUnsupported }
            if let device {
                try Self.property(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0))
                try Self.property(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1))
                try Self.property(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
            }
            let format = Self.format(rate: rate, channels: channels)
            for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
                try Self.property(speed, kAudioUnitProperty_StreamFormat, scope, 0, format)
            }
            try Self.property(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format)
            if device == nil {
                try Self.property(
                    output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                    Self.format(rate: outputRate, channels: channels))
            } else {
                // Client channel indices map to physical channels 1 and 2; other outputs stay silent.
                var map: [Int32] = (0..<(physicalChannels ?? channels)).map { $0 < channels ? Int32($0) : -1 }
                try map.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { throw EngineError.formatUnsupported }
                    try checkHAL(
                        AudioUnitSetProperty(
                            output, kAudioOutputUnitProperty_ChannelMap,
                            kAudioUnitScope_Output, 0, base, UInt32(bytes.count)), "Monitor channel map")
                }
            }
            let maximum: UInt32 = 16384
            try Self.property(speed, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
            try Self.property(output, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
            let callback = AURenderCallbackStruct(
                inputProc: mb_monitor_render, inputProcRefCon: UnsafeMutableRawPointer(context))
            try Self.property(speed, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, callback)
            let connection = AudioUnitConnection(sourceAudioUnit: speed, sourceOutputNumber: 0, destInputNumber: 0)
            try Self.property(output, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, connection)
            try checkHAL(AudioUnitInitialize(speed), "Initialize monitor Varispeed")
            try checkHAL(AudioUnitInitialize(output), "Initialize monitor output")
            for unit in [speed, output] {
                var latency: Float64 = 0
                var size = UInt32(MemoryLayout<Float64>.size)
                try checkHAL(
                    AudioUnitGetProperty(
                        unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global,
                        0, &latency, &size), "Monitor unit latency")
                latencySeconds += latency
            }

        } catch {
            try stop()
            throw error
        }
    }
    static func format(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
    }
    private static func unit(_ type: OSType, _ subtype: OSType) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: type, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw EngineError.formatUnsupported }
        var unit: AudioUnit?
        try checkHAL(AudioComponentInstanceNew(component, &unit), "Create monitor unit")
        guard let unit else { throw EngineError.formatUnsupported }
        return unit
    }
    private static func property<T>(
        _ unit: AudioUnit, _ id: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: T
    ) throws {
        var value = value
        try checkHAL(
            AudioUnitSetProperty(unit, id, scope, element, &value, UInt32(MemoryLayout<T>.size)),
            "Monitor unit property \(id)")
    }
    func start() throws {
        guard let output else { throw EngineError.formatUnsupported }
        try checkHAL(AudioOutputUnitStart(output), "Start monitor AUHAL")
        started = true
    }
    func setCorrection(_ correction: Double) throws {
        guard let speed else { return }
        try checkHAL(
            AudioUnitSetParameter(
                speed, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global,
                0, Float(1 + min(0.005, max(-0.005, correction))), 0), "Monitor drift correction")
    }
    func render(frames: UInt32, timestamp: inout AudioTimeStamp, output buffers: UnsafeMutablePointer<AudioBufferList>)
        throws
    {
        guard let output else { throw EngineError.formatUnsupported }
        var flags: AudioUnitRenderActionFlags = []
        try checkHAL(AudioUnitRender(output, &flags, &timestamp, 0, frames, buffers), "Offline monitor render")
    }
    func stop() throws {
        if let output {
            if started {
                try checkHAL(AudioOutputUnitStop(output), "Stop monitor AUHAL")
                started = false
            }
            try checkHAL(AudioUnitUninitialize(output), "Uninitialize monitor output")
            try checkHAL(AudioComponentInstanceDispose(output), "Dispose monitor output")
            self.output = nil
        }
        if let speed {
            try checkHAL(AudioUnitUninitialize(speed), "Uninitialize monitor Varispeed")
            try checkHAL(AudioComponentInstanceDispose(speed), "Dispose monitor Varispeed")
            self.speed = nil
        }
    }
}
