import AudioToolbox
import Foundation
import MicBoostDSP
import Testing

func monitorRender(_ context: OpaquePointer, frames: Int, channels: Int = 2, host: UInt64 = 0) -> [[Float]] {
    let list = AudioBufferList.allocate(maximumBuffers: channels)
    defer { list.unsafeMutablePointer.deallocate() }
    let samples = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    defer { for pointer in samples { pointer.deallocate() } }
    list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels)
    for c in 0..<channels {
        list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: samples[c])
    }
    var flags: AudioUnitRenderActionFlags = []
    var time = AudioTimeStamp()
    time.mHostTime = host
    time.mFlags = .hostTimeValid
    _ = mb_monitor_render(UnsafeMutableRawPointer(context), &flags, &time, 0, UInt32(frames), list.unsafeMutablePointer)
    return samples.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
}
func monitorPush(_ engine: OpaquePointer, frames: Int, left: Float = 0.2, right: Float = -0.1, host: UInt64 = 1) {
    let l = Array(repeating: left, count: frames)
    let r = Array(repeating: right, count: frames)
    l.withUnsafeBufferPointer { lp in
        r.withUnsafeBufferPointer { rp in
            if let l = lp.baseAddress, let r = rp.baseAddress { mb_monitor_write(engine, l, r, UInt32(frames), host) }
        }
    }
}
@Test func monitorRingChannelsSilenceFadesAndHostLatency() throws {
    for channels in [1, 2, 8] {
        let engine = try #require(mb_engine_create(256, 48000))
        defer { mb_engine_destroy(engine) }
        let monitor = try #require(mb_monitor_create(engine, 48000, 512))
        defer {
            mb_engine_set_monitor_enabled(engine, false)
            mb_monitor_destroy(monitor)
        }
        mb_engine_set_monitor_enabled(engine, true)
        #expect(monitorRender(monitor, frames: 512, channels: channels).flatMap { $0 }.allSatisfy { $0 == 0 })
        monitorPush(engine, frames: 1024, host: 1_000_000)
        let output = monitorRender(monitor, frames: 512, channels: channels, host: 2_000_000)
        let expected: Float = channels == 1 ? 0.05 : 0.2
        #expect(abs(output[0][511] - expected) < 0.000001)
        #expect(abs(output[0][0]) < 0.001)
        for pair in zip(output[0], output[0].dropFirst()) { #expect(abs(pair.1 - pair.0) < 0.001) }
        if channels == 8 { #expect(output[2...].flatMap { $0 }.allSatisfy { $0 == 0 }) }
        var stats = mb_monitor_stats()
        mb_monitor_read(monitor, &stats)
        #expect(stats.latency_host == 1_000_000)
        mb_monitor_set_silent(monitor, true)
        let silent = monitorRender(monitor, frames: 256, channels: channels)
        #expect(silent.flatMap { $0 }.allSatisfy { $0 == 0 })
        mb_monitor_read(monitor, &stats)
        #expect(stats.fill == 256)
        mb_monitor_set_silent(monitor, false)
        monitorPush(engine, frames: 512)
        mb_monitor_fade_out(monitor)
        let faded = monitorRender(monitor, frames: 512, channels: channels)
        #expect(faded[0].suffix(32).allSatisfy { abs($0) < 0.00001 })
    }
}
@Test func monitorRingUnderrunOverrunAndDisabledProducer() throws {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let monitor = try #require(mb_monitor_create(engine, 48000, 512))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(monitor)
    }
    monitorPush(engine, frames: 256)
    var stats = mb_monitor_stats()
    mb_monitor_read(monitor, &stats)
    #expect(stats.fill == 512)
    _ = monitorRender(monitor, frames: 1024)
    mb_monitor_read(monitor, &stats)
    #expect(stats.underruns == 1)
    mb_engine_set_monitor_enabled(engine, true)
    monitorPush(engine, frames: 9000)
    _ = monitorRender(monitor, frames: 256)
    mb_monitor_read(monitor, &stats)
    #expect(stats.overruns_full + stats.resets >= 1)
    #expect(stats.fill <= stats.target)
}
@Test(arguments: [-0.003, -0.0002, 0.0002, 0.003])
func monitorPIControlsSimulatedDrift(_ drift: Double) {
    var pi = mb_monitor_pi()
    var fill = 560.0
    var minimum = fill
    var maximum = fill
    var correction = 0.0
    for _ in 0..<1200 {
        correction = mb_monitor_pi_update(&pi, fill - 560, 48000, 0.05)
        #expect(abs(correction) <= 0.005)
        fill += 48000 * 0.05 * (1 - (1 + correction) / (1 + drift))
        minimum = min(minimum, fill)
        maximum = max(maximum, fill)
    }
    print(
        "monitor drift=\(drift) min_fill=\(minimum) max_fill=\(maximum) final_fill=\(fill) correction_ppm=\(correction*1e6)"
    )
    #expect(minimum > 100 && maximum < 1024)
    #expect(abs(fill - 560) < 0.01)
    #expect(abs(correction - drift) < 0.000001)
}

@Test func monitorLargeTargetRefillsWithSilenceAfterExtremeDeficit() throws {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let context = try #require(mb_monitor_create(engine, 48000, 7000))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(context)
    }
    mb_engine_set_monitor_enabled(engine, true)
    _ = monitorRender(context, frames: 7000)
    _ = monitorRender(context, frames: 256)
    monitorPush(engine, frames: 256)
    var stats = mb_monitor_stats()
    mb_monitor_read(context, &stats)
    #expect(stats.fill == 7256)
    #expect(stats.overruns_full + stats.resets >= 1)
}

@Test func monitorContextRetainsRingAfterEngineOwnerIsReleased() throws {
    let engine = try #require(mb_engine_create(256, 48000))
    let context = try #require(mb_monitor_create(engine, 48000, 512))
    mb_engine_set_monitor_enabled(engine, false)
    mb_engine_destroy(engine)
    #expect(monitorRender(context, frames: 256).flatMap { $0 }.allSatisfy { $0 == 0 })
    mb_monitor_destroy(context)
}

@Test(arguments: [-0.003, -0.0002, 0.0002, 0.003])
func monitorAdaptsToIrregularBluetoothPulls(_ drift: Double) throws {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let context = try #require(mb_monitor_create(engine, 48000, 1419))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(context)
    }
    mb_monitor_set_target_base(context, 256, 1115)
    mb_engine_set_monitor_enabled(engine, true)
    let blocks = [1024, 2048, 1536, 2048, 1024]
    let jitter = [0.001, -0.001, 0.0005, -0.0005, 0.0]
    var producer = 0.0
    var consumer = 0.0
    var controller = 0.05
    var block = 0
    var fraction = 0.0
    var correction = 0.0
    var pi = mb_monitor_pi()
    var baselineFull: UInt64 = 0
    var baselineResets: UInt64 = 0
    var baselineUnder: UInt64 = 0
    var minimum = UInt32.max
    var maximum: UInt32 = 0
    var maxPull: UInt32 = 0
    var stats = mb_monitor_stats()
    while min(producer, consumer, controller) < 60 {
        let now = min(producer, consumer, controller)
        if producer <= now {
            monitorPush(engine, frames: 256)
            producer += 256.0 / 48000
        }
        if consumer <= now {
            let frames = blocks[block % blocks.count]
            let requested = Double(frames) * 48000 / 44100 * (1 + correction) + fraction
            let pull = Int(requested.rounded(.down))
            fraction = requested - Double(pull)
            _ = monitorRender(context, frames: pull)
            consumer += Double(frames) / 44100 / (1 + drift) + jitter[block % jitter.count]
            block += 1
        }
        if controller <= now {
            mb_monitor_read(context, &stats)
            correction = mb_monitor_pi_update(&pi, Double(stats.fill) - Double(stats.target), 48000, 0.05)
            #expect(abs(correction) <= 0.005)
            maxPull = max(maxPull, stats.max_pull)
            if now < 1 {
                baselineFull = stats.overruns_full
                baselineResets = stats.resets
                baselineUnder = stats.underruns
            } else {
                minimum = min(minimum, stats.fill_min)
                maximum = max(maximum, stats.fill_max)
            }
            controller += 0.05
        }
    }
    mb_monitor_peek(context, &stats)
    print(
        "irregular drift=\(drift) fill_min=\(minimum) fill_max=\(maximum) target=\(stats.target) max_pull=\(maxPull) full_after_settle=\(stats.overruns_full-baselineFull) resets_after_settle=\(stats.resets-baselineResets) underruns_after_settle=\(stats.underruns-baselineUnder) startup_underruns=\(baselineUnder)"
    )
    #expect(stats.overruns_full == baselineFull)
    #expect(stats.resets == baselineResets)
    #expect(stats.underruns == baselineUnder)
    #expect(minimum > 0 && maximum < 8192)
    #expect(maxPull > 2200)
    #expect(stats.target >= 256 + maxPull + 48)
}

@Test func monitorMetricsSeparateFullDropsResetsAndResetReadWindows() throws {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let context = try #require(mb_monitor_create(engine, 48000, 512))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(context)
    }
    mb_engine_set_monitor_enabled(engine, true)
    monitorPush(engine, frames: 5000)
    _ = monitorRender(context, frames: 256)
    var stats = mb_monitor_stats()
    mb_monitor_read(context, &stats)
    #expect(stats.resets == 1)
    #expect(stats.overruns_full == 0)
    #expect(stats.max_pull == 256)
    #expect(stats.fill_max >= 5512)
    mb_monitor_read(context, &stats)
    #expect(stats.max_pull == 0)
    monitorPush(engine, frames: 9000)
    _ = monitorRender(context, frames: 1024)
    mb_monitor_read(context, &stats)
    #expect(stats.overruns_full == 1)
    #expect(stats.resets == 2)
    #expect(stats.max_pull == 1024)
}
