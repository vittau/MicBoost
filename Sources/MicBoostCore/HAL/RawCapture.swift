import CoreAudio
import Foundation
import MicBoostDSP

extension CoreAudioHardware {
    public func capture(device: AudioDevice, seconds: Double, destination: URL) throws -> String {
        guard seconds.isFinite, seconds > 0, seconds <= 300, device.inputChannels > 0 else {
            throw EngineError.invalidArgument("Capture duration must be 0 < seconds <= 300 and device must have input")
        }
        let streams = try values(
            .init(device.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), as: AudioStreamID.self)
        guard !streams.isEmpty else { throw EngineError.formatUnsupported }
        for stream in streams {
            let format = try scalar(
                .init(stream, kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0, format.mBitsPerChannel == 32,
                format.mSampleRate == device.sampleRate
            else { throw EngineError.formatUnsupported }
        }
        let capacity = Int(ceil(device.sampleRate * seconds))
        guard let context = mb_capture_create(capacity, device.inputChannels) else {
            throw EngineError.invalidArgument("Cannot allocate capture buffer")
        }
        // Destruction is only safe once the IOProc has been destroyed.
        var proc: AudioDeviceIOProcID?
        do {
            try checkHAL(
                AudioDeviceCreateIOProcID(device.id, mb_capture_ioproc, UnsafeMutableRawPointer(context), &proc),
                "Create capture IOProc")
        } catch {
            mb_capture_destroy(context)
            throw error
        }
        guard let proc else {
            mb_capture_destroy(context)
            throw EngineError.formatUnsupported
        }
        do { try checkHAL(AudioDeviceStart(device.id, proc), "Start capture") } catch {
            try checkHAL(AudioDeviceDestroyIOProcID(device.id, proc), "Destroy failed capture IOProc")
            mb_capture_destroy(context)
            throw error
        }
        Thread.sleep(forTimeInterval: seconds)
        let stopStatus = AudioDeviceStop(device.id, proc)
        try checkHAL(AudioDeviceDestroyIOProcID(device.id, proc), "Destroy capture IOProc")
        defer { mb_capture_destroy(context) }
        try checkHAL(stopStatus, "Stop capture")
        let frames = mb_capture_frames(context)
        let channels = Int(device.inputChannels)
        let samples = mb_capture_samples(context)
        let byteCount = frames * channels * 4
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var n = value.littleEndian
            withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var n = value.littleEndian
            withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
        }
        text("RIFF")
        u32(UInt32(36 + byteCount))
        text("WAVEfmt ")
        u32(16)
        u16(3)
        u16(UInt16(channels))
        u32(UInt32(device.sampleRate))
        u32(UInt32(device.sampleRate) * UInt32(channels) * 4)
        u16(UInt16(channels * 4))
        u16(32)
        text("data")
        u32(UInt32(byteCount))
        wav.append(
            UnsafeBufferPointer(start: UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount))
        try wav.write(to: destination, options: .atomic)
        var lines = ["Captured \(frames) frames at \(device.sampleRate) Hz from \(device.name) [\(device.uid)]"]
        for channel in 0..<channels {
            var peak: Double = 0
            var sum: Double = 0
            for frame in 0..<frames {
                let sample = Double(samples[frame * channels + channel])
                peak = max(peak, abs(sample))
                sum += sample * sample
            }
            lines.append(
                "channel \(channel + 1): peak=\(peak) rms=\(frames > 0 ? sqrt(sum / Double(frames)) : 0) nonZero=\(peak > 0)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
