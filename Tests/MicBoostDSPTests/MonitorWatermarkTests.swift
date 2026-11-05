import Darwin
import Foundation
import MicBoostDSP
import Testing

private struct QueueResult {
    var mean = 0.0
    var minimumCorrection = Double.infinity
    var maximumCorrection = -Double.infinity
    var maximumStep = 0.0
    var underruns: UInt64 = 0
    var full: UInt64 = 0
    var resets: UInt64 = 0
    var startupUnderruns: UInt64 = 0
    var settlingUnderruns: UInt64 = 0
    var lastUnderrunTime = 0.0
    var afterTwoSeconds: UInt64 = 0
}

private func queueSimulation(drift: Double, scenario: Int, acquire: Bool) throws -> QueueResult {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let outputRate = scenario == 2 ? 48000.0 : 44100.0
    let blocks =
        scenario == 0
        ? [320]
        : scenario == 1
            ? [1024, 2048, 1536, 2048, 1024]
            : scenario == 2 ? [512] : [1024]
    let jitter = [0.001, -0.001, 0.0005, -0.0005, 0.0]
    let initialPull = Int(ceil(Double(blocks[0]) * 48000 / outputRate))
    let initial = 256 + initialPull + 48
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = 1e9 * Double(timebase.denom) / Double(timebase.numer)
    func host(_ seconds: Double) -> UInt64 { 1_000_000_000 + UInt64((seconds * ticks).rounded()) }
    var outputPosition = 0.0
    let context = try #require(mb_monitor_create(engine, 48000, UInt32(initial)))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(context)
    }
    mb_monitor_set_target_base(context, 256, UInt32(initialPull))
    mb_engine_set_monitor_enabled(engine, true)
    var producer = 0.0
    var consumer = 0.3  // Delayed AUHAL first render, with the producer already running.
    var controller = 0.05
    var block = 0
    var fraction = 0.0
    var correction = 0.0
    var pi = mb_monitor_pi()
    var stats = mb_monitor_stats()
    var baseline = mb_monitor_stats()
    var result = QueueResult()
    var renders = 0
    var previousUnderruns: UInt64 = 0
    var twoSecondUnderruns: UInt64 = 0
    while min(producer, consumer, controller) < 300 {
        let now = min(producer, consumer, controller)
        if producer <= now {
            monitorPush(engine, frames: 256, host: host(producer))
            producer += 256.0 / 48000
        }
        if consumer <= now {
            let frames = blocks[block % blocks.count]
            let requested = Double(frames) * 48000 / outputRate * (1 + correction) + fraction
            let pull = Int(requested.rounded(.down))
            fraction = requested - Double(pull)
            if now >= 180 {
                mb_monitor_peek(context, &stats)
                result.mean += Double(stats.fill)
                renders += 1
            }
            // HAL timestamps describe scheduled audio time; callback jitter changes invocation time only.
            let scheduled = 0.3 + outputPosition / outputRate * (1 + drift) + Double(blocks[0]) / outputRate
            _ = monitorRender(context, frames: pull, host: host(scheduled))
            outputPosition += Double(frames)
            // Positive drift means the consumer clock is slower than the producer's clock.
            consumer += Double(frames) / outputRate * (1 + drift) + jitter[block % jitter.count]
            block += 1
        }
        if controller <= now {
            mb_monitor_read(context, &stats)
            if stats.underruns > previousUnderruns { result.lastUnderrunTime = now }
            previousUnderruns = stats.underruns
            if acquire { mb_monitor_pi_observe_clock(&pi, &stats, 48000, 0.05) }
            let next =
                stats.pulling
                ? mb_monitor_pi_update(
                    &pi, Double(stats.fill_min) - Double(stats.target), 48000, 0.05,
                    Double(stats.quantum)) : 0
            mb_monitor_set_correction(context, next)
            if now < 2 { twoSecondUnderruns = stats.underruns }
            if now < 1 { result.startupUnderruns = stats.underruns }
            if now < 180 {
                baseline = stats
            } else {
                result.minimumCorrection = min(result.minimumCorrection, next)
                result.maximumCorrection = max(result.maximumCorrection, next)
                result.maximumStep = max(result.maximumStep, abs(next - correction))
            }
            correction = next
            controller += 0.05
        }
    }
    mb_monitor_peek(context, &stats)
    result.afterTwoSeconds = stats.underruns - twoSecondUnderruns
    result.mean /= Double(renders)
    result.underruns = stats.underruns - baseline.underruns
    result.settlingUnderruns = baseline.underruns
    result.full = stats.overruns_full
    result.resets = stats.resets
    return result
}

@Test(arguments: [-0.003, -0.0015, -0.0002, 0, 0.0002, 0.003], [0, 1, 2, 3])
func watermarkControllerHandlesDriftAndDelayedIrregularConsumer(_ drift: Double, _ scenario: Int) throws {
    let before = try queueSimulation(drift: drift, scenario: scenario, acquire: false)
    let after = try queueSimulation(drift: drift, scenario: scenario, acquire: true)
    print(
        "watermark scenario=\(scenario) drift=\(drift) before_frames=\(before.mean) after_frames=\(after.mean) before_ms=\(before.mean/48) after_ms=\(after.mean/48) correction_ppm=\(after.minimumCorrection*1e6)...\(after.maximumCorrection*1e6) step_ppm=\(after.maximumStep*1e6) before_step_ppm=\(before.maximumStep*1e6) before_acquisition=\(before.settlingUnderruns) after_2s=\(after.afterTwoSeconds) full=\(after.full) resets=\(after.resets) underruns=\(after.underruns) startup_underruns=\(after.startupUnderruns) settling_underruns=\(after.settlingUnderruns) last_underrun_s=\(after.lastUnderrunTime)"
    )
    #expect(after.full == 0 && after.resets == 0 && after.underruns == 0)
    #expect(after.startupUnderruns <= 4)
    #expect(after.settlingUnderruns <= 500)
    #expect(abs(after.minimumCorrection - drift) < 0.00075)
    #expect(abs(after.maximumCorrection - drift) < 0.00075)
    #expect(after.maximumStep <= 0.000050001)
    #expect(abs(after.minimumCorrection) < 0.004 && abs(after.maximumCorrection) < 0.004)
    #expect(after.mean <= before.mean * 1.05)
    #expect(after.afterTwoSeconds == 0)
}

@Test func monitorPIClampsWithoutWindupAndLimitsSlew() {
    var pi = mb_monitor_pi()
    var previous = 0.0
    for _ in 0..<600 {
        let correction = mb_monitor_pi_update(&pi, 48000, 48000, 0.05, 256)
        #expect(abs(correction - previous) <= 0.000050001)
        #expect(abs(correction) <= 0.005)
        previous = correction
    }
    let integral = pi.integral
    for _ in 0..<100 { _ = mb_monitor_pi_update(&pi, 48000, 48000, 0.05, 256) }
    #expect(pi.integral == integral)
    #expect(pi.correction == 0.005)
    for _ in 0..<600 { _ = mb_monitor_pi_update(&pi, -48000, 48000, 0.05, 256) }
    #expect(pi.correction == -0.005)
}

@Test func monitorProducerWaitsForFirstPullWithoutOverflow() throws {
    let engine = try #require(mb_engine_create(256, 48000))
    defer { mb_engine_destroy(engine) }
    let context = try #require(mb_monitor_create(engine, 48000, 655))
    defer {
        mb_engine_set_monitor_enabled(engine, false)
        mb_monitor_destroy(context)
    }
    mb_monitor_set_target_base(context, 256, 351)
    mb_engine_set_monitor_enabled(engine, true)
    _ = monitorRender(context, frames: 0)
    for _ in 0..<60 { monitorPush(engine, frames: 256) }
    var stats = mb_monitor_stats()
    mb_monitor_read(context, &stats)
    #expect(stats.target == 216 && stats.fill == 823)
    #expect(!stats.pulling && stats.overruns_full == 0 && stats.resets == 0)
    _ = monitorRender(context, frames: 351)
    mb_monitor_read(context, &stats)
    #expect(stats.pulling && stats.underruns == 0)
    monitorPush(engine, frames: 256)
    mb_monitor_read(context, &stats)
    #expect(stats.fill == 728 && stats.overruns_full == 0 && stats.resets == 0)
}

@Test func monitorMarginUsesBufferGeometryAndControllerUsesCallbackTime() throws {
    for (rate, buffer, pull) in [(48000.0, 256, 351), (44100, 128, 1024), (96000, 512, 512)] {
        let engine = try #require(mb_engine_create(UInt32(buffer), rate))
        defer { mb_engine_destroy(engine) }
        let context = try #require(mb_monitor_create(engine, rate, 1))
        defer { mb_monitor_destroy(context) }
        mb_monitor_set_target_base(context, UInt32(buffer), UInt32(pull))
        var stats = mb_monitor_stats()
        mb_monitor_peek(context, &stats)
        let quantum = max(buffer, pull)
        #expect(stats.quantum == UInt32(quantum))
        #expect(stats.target == UInt32(ceil(Double(buffer) / 2 + Double(quantum) / 4)))
        #expect(stats.fill == UInt32(buffer + pull) + stats.target)
    }
    var fast = mb_monitor_pi()
    var slow = mb_monitor_pi()
    let normal = mb_monitor_pi_update(&fast, 48000, 48000, 0.05, 256)
    let longCallback = mb_monitor_pi_update(&slow, 48000, 48000, 0.05, 48000)
    #expect(abs(normal - 0.00005) < 1e-10)
    #expect(abs(longCallback - 0.0000125) < 1e-10)
    #expect(fast.integral == 0 && slow.integral == 0)
}

@Test func clockFeedForwardUsesTimestampIntervalsAndBoundsAcquisitionSlew() {
    var pi = mb_monitor_pi()
    var stats = mb_monitor_stats()
    stats.quantum = 351
    stats.host_ticks_per_second = 1_000_000
    #expect(!mb_monitor_pi_observe_clock(&pi, &stats, 48000, 0.05))
    stats.producer_host = 1_000_000
    stats.consumer_host = 5_000_000  // Arbitrary input/output latency offsets cancel.
    #expect(!mb_monitor_pi_observe_clock(&pi, &stats, 48000, 0.05))
    stats.producer_host += 100_000
    stats.consumer_host += 100_000
    stats.producer_frames = 4800
    stats.consumer_frames = 4800 / (1 - 0.003)
    #expect(mb_monitor_pi_observe_clock(&pi, &stats, 48000, 0.05))
    #expect(abs(pi.integral + 0.003) < 1e-10)
    let first = mb_monitor_pi_update(&pi, 0, 48000, 0.05, 351)
    #expect(abs(first + 0.0025) < 1e-10)
    let second = mb_monitor_pi_update(&pi, 0, 48000, 0.05, 351)
    #expect(abs(second + 0.003) < 1e-10 && !pi.acquiring)
    #expect(!mb_monitor_pi_observe_clock(&pi, &stats, 48000, 0.05))

    var invalid = mb_monitor_pi()
    stats.producer_frames = 0
    stats.consumer_frames = 0
    #expect(!mb_monitor_pi_observe_clock(&invalid, &stats, 48000, 0.05))
    stats.producer_host += 100_000
    stats.consumer_host += 100_000
    stats.producer_frames = 4800
    stats.consumer_frames = 4000  // Outside the specified clock-correction budget.
    #expect(!mb_monitor_pi_observe_clock(&invalid, &stats, 48000, 0.05))
    #expect(!invalid.clock_acquired && invalid.integral == 0)
}
