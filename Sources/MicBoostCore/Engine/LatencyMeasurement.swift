import Accelerate
import CoreAudio
import Darwin
import Foundation
import MicBoostDSP

public struct LatencyMeasurement: Sendable {
    public static func monitorMilliseconds(sourceToBlackHole: Double, output: HardwareLatency, sampleRate: Double)
        -> Double
    {
        sourceToBlackHole + Double(output.total) * 1000 / sampleRate
    }
    public let milliseconds: Double
    public let correlation: Double
    public let sourcePeak: Float
    public let destinationPeak: Float
}
extension CoreAudioHardware {
    /// Capture both clocks concurrently; correlate room audio without playing a sound.
    public func measureLatency(source: AudioDevice, destination: AudioDevice) throws -> LatencyMeasurement {
        let seconds = 2.0
        let capacity = Int(source.sampleRate * seconds)
        guard let a = mb_capture_create(capacity, source.inputChannels) else { throw EngineError.formatUnsupported }
        guard let b = mb_capture_create(capacity, destination.inputChannels) else {
            mb_capture_destroy(a)
            throw EngineError.formatUnsupported
        }
        var pa: AudioDeviceIOProcID?
        var pb: AudioDeviceIOProcID?
        var startedA = false
        var startedB = false
        func cleanup() throws {
            var failure: Error?
            func checked(_ status: OSStatus, _ operation: String) {
                do { try checkHAL(status, operation) } catch { failure = error }
            }
            if let pa {
                if startedA { checked(AudioDeviceStop(source.id, pa), "Stop latency source") }
                let status = AudioDeviceDestroyIOProcID(source.id, pa)
                checked(status, "Destroy latency source")
                if status == noErr { selfFreeA() }
            }
            if let pb {
                if startedB { checked(AudioDeviceStop(destination.id, pb), "Stop latency destination") }
                let status = AudioDeviceDestroyIOProcID(destination.id, pb)
                checked(status, "Destroy latency destination")
                if status == noErr { selfFreeB() }
            }
            if let failure { throw failure }
        }
        // Capture storage stays alive until samples have been inspected.
        func selfFreeA() { pa = nil }
        func selfFreeB() { pb = nil }
        defer {
            if pa == nil { mb_capture_destroy(a) }
            if pb == nil { mb_capture_destroy(b) }
        }
        do {
            try checkHAL(
                AudioDeviceCreateIOProcID(source.id, mb_capture_ioproc, UnsafeMutableRawPointer(a), &pa),
                "Latency source IOProc")
            try checkHAL(
                AudioDeviceCreateIOProcID(destination.id, mb_capture_ioproc, UnsafeMutableRawPointer(b), &pb),
                "Latency destination IOProc")
            guard let sourceProc = pa, let destinationProc = pb else { throw EngineError.formatUnsupported }
            try checkHAL(AudioDeviceStart(source.id, sourceProc), "Start latency source")
            startedA = true
            try checkHAL(AudioDeviceStart(destination.id, destinationProc), "Start latency destination")
            startedB = true
            Thread.sleep(forTimeInterval: seconds)
        } catch {
            try cleanup()
            throw error
        }
        try cleanup()
        let na = mb_capture_frames(a)
        let nb = mb_capture_frames(b)
        let va = mb_capture_samples(a)
        let vb = mb_capture_samples(b)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let hostSeconds =
            (Double(mb_capture_host_time(b)) - Double(mb_capture_host_time(a)))
            * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let offset = Int((hostSeconds * source.sampleRate).rounded())
        let x = (0..<na).map { va[$0 * Int(source.inputChannels)] }
        let y = (0..<nb).map { vb[$0 * Int(destination.inputChannels)] }
        let radius = Int(source.sampleRate * 0.1)
        let length = min(na, nb) - 2 * radius - abs(offset)
        guard length > 1000 else { throw EngineError.invalidArgument("Insufficient latency capture") }
        let start = radius + max(0, offset)
        var best: Double = -1
        var lag = 0
        let energy = x[start..<(start + length)].reduce(0.0) { $0 + Double($1) * Double($1) }
        for candidate in -radius...radius {
            let other = start - offset + candidate
            guard other >= 0, other + length <= nb else { continue }
            var dot: Float = 0
            var norm: Float = 0
            x.withUnsafeBufferPointer { xp in
                y.withUnsafeBufferPointer { yp in
                    if let xx = xp.baseAddress, let yy = yp.baseAddress {
                        vDSP_dotpr(xx + start, 1, yy + other, 1, &dot, vDSP_Length(length))
                        vDSP_svesq(yy + other, 1, &norm, vDSP_Length(length))
                    }
                }
            }
            let score = Double(dot) / sqrt(max(energy * Double(norm), 1e-30))
            if score > best {
                best = score
                lag = candidate
            }
        }
        guard best >= 0.5 else {
            throw EngineError.invalidArgument(
                "Room signal cannot establish latency: correlation=\(best); snap fingers near the microphone and retry")
        }
        return LatencyMeasurement(
            milliseconds: Double(lag) * 1000 / source.sampleRate,
            correlation: best, sourcePeak: x.map(abs).max() ?? 0, destinationPeak: y.map(abs).max() ?? 0)
    }
}
