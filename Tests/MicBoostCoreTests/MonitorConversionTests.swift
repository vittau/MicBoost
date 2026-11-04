import AudioToolbox
import Foundation
import MicBoostDSP
import Testing

@testable import MicBoostCore

@Test(arguments: [0.0, -0.005, 0.005])
func systemMonitorConversionOffline(_ correction: Double) throws {
    for (inputRate, outputRate) in [(48000.0, 44100.0), (44100.0, 48000.0)] {
        let engine = try #require(mb_engine_create(8192, inputRate))
        defer { mb_engine_destroy(engine) }
        let context = try #require(mb_monitor_create(engine, inputRate, 2048))
        defer {
            mb_engine_set_monitor_enabled(engine, false)
            mb_monitor_destroy(context)
        }
        mb_engine_set_monitor_enabled(engine, true)
        let chain = try MonitorAudioUnits(
            context: context, rate: inputRate, channels: 2,
            device: nil, outputRate: outputRate, buffer: 256)
        defer { try? chain.stop() }
        try chain.setCorrection(correction)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        list.unsafeMutablePointer.pointee.mNumberBuffers = 2
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var generated = 0
        var rendered: [Double] = []
        var time = AudioTimeStamp()
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        for block in 0..<Int(ceil(outputRate * 2 / 256)) {
            var stats = mb_monitor_stats()
            mb_monitor_read(context, &stats)
            let needed = max(0, 3000 - Int(stats.fill))
            if needed > 0 {
                let samples = (0..<needed).map {
                    Float(0.25 * sin(2 * Double.pi * 1000 * Double(generated + $0) / inputRate))
                }
                samples.withUnsafeBufferPointer { p in
                    if let base = p.baseAddress {
                        mb_monitor_write(engine, base, base, UInt32(needed), UInt64(generated + 1))
                    }
                }
                generated += needed
            }
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: left)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: right)
            if block == Int(outputRate * 0.1 / 256) { try chain.setCorrection(-correction) }
            if block == Int(outputRate * 0.25 / 256) { try chain.setCorrection(correction) }
            time.mSampleTime = Double(block * 256)
            time.mHostTime = UInt64(block * 1_000_000 + 100_000_000)
            try chain.render(frames: 256, timestamp: &time, output: list.unsafeMutablePointer)
            rendered.append(contentsOf: UnsafeBufferPointer(start: left, count: 256).map(Double.init))
        }
        let transitionStep = zip(rendered, rendered.dropFirst()).map { abs($0.1 - $0.0) }.max() ?? 0
        #expect(transitionStep < 0.05)
        let values = Array(rendered[Int(outputRate / 2)..<Int(outputRate * 1.5)])
        let frequency = 1000 * (1 + correction)
        var cosine = 0.0
        var sine = 0.0
        var energy = 0.0
        for (i, x) in values.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(i) / outputRate
            cosine += x * cos(phase)
            sine += x * sin(phase)
            energy += x * x
        }
        cosine *= 2 / Double(values.count)
        sine *= 2 / Double(values.count)
        #expect(abs(sqrt(cosine * cosine + sine * sine) - 0.25) < 0.005)
        var residual = 0.0
        var maxStep = 0.0
        for (i, x) in values.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(i) / outputRate
            let error = x - cosine * cos(phase) - sine * sin(phase)
            residual += error * error
            if i > 0 { maxStep = max(maxStep, abs(x - values[i - 1])) }
        }
        let thdn = 10 * log10(max(1e-30, residual / energy))
        print(
            "system monitor \(inputRate)->\(outputRate) correction=\(correction) THD+N_dB=\(thdn) max_step=\(maxStep) transition_max_step=\(transitionStep) unit_latency_s=\(chain.latencySeconds)"
        )
        #expect(thdn <= -60)
        #expect(maxStep < 0.05)
        var stats = mb_monitor_stats()
        mb_monitor_read(context, &stats)
        #expect(stats.underruns == 0)
        #expect(stats.overruns == 0)
    }
}
