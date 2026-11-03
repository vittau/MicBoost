import Foundation
import MicBoostDSP
import Testing

private let rates = [16000.0, 44100, 48000, 96000]

private func settle(_ engine: OpaquePointer, rate: Double) {
    _ = process(engine, [Array(repeating: 0, count: Int(rate * 0.65))])
}

@Test(arguments: rates) func flatGainMuteLimiter(rate: Double) throws {
    let engine = try #require(mb_engine_create(64, rate))
    defer { mb_engine_destroy(engine) }
    var seed: UInt64 = 42
    let noise: [Float] = (0..<4096).map { _ in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Float(Int64(bitPattern: seed)) / Float(Int64.max) * 0.4
    }
    #expect(process(engine, [noise])[0] == noise)
    mb_engine_set_gain_db(engine, 12)
    let step = process(engine, [Array(repeating: 0.1, count: Int(rate * 0.1))])[0]
    #expect(abs((step.last ?? 0) - 0.398107) < 0.003)
    #expect(zip(step, step.dropFirst()).allSatisfy { abs($0 - $1) < 0.002 })
    mb_engine_set_muted(engine, true)
    settle(engine, rate: rate)
    #expect(abs(process(engine, [[0.1]])[0][0]) < 1e-6)
    mb_engine_set_muted(engine, false)
    mb_engine_set_gain_db(engine, 24)
    mb_engine_set_band(engine, MB_MID, 1000, 12, 0.9)
    settle(engine, rate: rate)
    let sine = (0..<Int(rate * 0.1)).map { Float(sin(2 * .pi * 1000 * Double($0) / rate)) }
    let limited = process(engine, [sine])[0]
    #expect(limited.allSatisfy { $0.isFinite && abs($0) <= 0.891001 })
    var meters = mb_meters()
    mb_engine_read_meters(engine, &meters)
    #expect(meters.gr_max_db > 20)
    #expect(meters.input_clipped)
    mb_engine_begin_fade_out(engine)
    settle(engine, rate: rate)
    mb_engine_read_meters(engine, &meters)
    #expect(meters.fade_done)
}

// Independent complex transfer evaluation of the RBJ cookbook coefficients.
private func theory(_ band: mb_band, rate: Double, frequency: Double, db: Double, probe: Double) -> Double {
    let a = pow(10, db / 40)
    let w = 2 * Double.pi * frequency / rate
    let c = cos(w)
    let t = sin(w) * sqrt(2 * a)
    let b: [Double]
    let d: [Double]
    if band == MB_MID {
        let alpha = sin(w) / 1.8
        b = [1 + alpha * a, -2 * c, 1 - alpha * a]
        d = [1 + alpha / a, -2 * c, 1 - alpha / a]
    } else {
        let sign = band == MB_LOW ? 1.0 : -1.0
        b = [
            a * (a + 1 - sign * (a - 1) * c + t),
            2 * sign * a * (a - 1 - sign * (a + 1) * c),
            a * (a + 1 - sign * (a - 1) * c - t),
        ]
        d = [
            a + 1 + sign * (a - 1) * c + t,
            -2 * sign * (a - 1 + sign * (a + 1) * c),
            a + 1 + sign * (a - 1) * c - t,
        ]
    }
    func magnitude(_ coefficients: [Double]) -> Double {
        let angle = 2 * Double.pi * probe / rate
        let real = coefficients[0] + coefficients[1] * cos(angle) + coefficients[2] * cos(2 * angle)
        let imaginary = -coefficients[1] * sin(angle) - coefficients[2] * sin(2 * angle)
        return hypot(real, imaginary)
    }
    return 20 * log10(magnitude(b) / magnitude(d))
}

@Test(arguments: rates) func bandResponseAndBypass(rate: Double) throws {
    for (band, frequency, probes) in [
        (MB_LOW, 120.0, [20.0, 2000]), (MB_MID, 1000, [1000]),
        (MB_HIGH, 6000, [1000, rate * 0.4]),
    ] {
        for db in [-12.0, 12] {
            let engine = try #require(mb_engine_create(128, rate))
            defer { mb_engine_destroy(engine) }
            mb_engine_set_band(engine, band, Float(frequency), Float(db), 0.9)
            settle(engine, rate: rate)
            for probe in probes {
                let count = Int(rate * 0.3)
                let sine = (0..<count).map { Float(0.01 * sin(2 * .pi * probe * Double($0) / rate)) }
                let output = process(engine, [sine])[0]
                let start = count / 2
                let inputPower = sine[start...].reduce(0.0) { $0 + Double($1 * $1) }
                let outputPower = output[start...].reduce(0.0) { $0 + Double($1 * $1) }
                let measured = 10 * log10(outputPower / inputPower)
                #expect(abs(measured - theory(band, rate: rate, frequency: frequency, db: db, probe: probe)) < 0.1)
            }
            mb_engine_set_eq_enabled(engine, false)
            settle(engine, rate: rate)
            let input: [Float] = [0.01, -0.02, 0.03]
            #expect(process(engine, [input])[0] == input)
        }
    }
}

@Test(arguments: rates) func clampChangesAndNonfinite(rate: Double) throws {
    let engine = try #require(mb_engine_create(64, rate))
    defer { mb_engine_destroy(engine) }
    for frequency: Float in [20, 1e8, 1000] {
        mb_engine_set_band(engine, MB_HIGH, frequency, 12, 0.3)
        let input = (0..<Int(rate * 0.1)).map { Float(0.005 * sin(2 * .pi * 1000 * Double($0) / rate)) }
        let output = process(engine, [input])[0]
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.891001 })
        #expect(zip(output, output.dropFirst()).allSatisfy { abs($0 - $1) < 0.03 })
    }
    let output = process(engine, [[.nan, .infinity, -.infinity, 0]])[0]
    #expect(output.allSatisfy { $0.isFinite })
    var counters = mb_counters()
    mb_engine_read_counters(engine, &counters)
    #expect(counters.nonfinite_resets == 1)
}

@Test(arguments: rates) func frequencyClampAndLinkedStereo(rate: Double) throws {
    let a = try #require(mb_engine_create(64, rate))
    let b = try #require(mb_engine_create(64, rate))
    defer {
        mb_engine_destroy(a)
        mb_engine_destroy(b)
    }
    for (requested, effective) in [(1e8, rate * 0.45), (1.0, 20.0)] {
        mb_engine_set_band(a, MB_HIGH, Float(requested), 12, 0.9)
        mb_engine_set_band(b, MB_HIGH, Float(effective), 12, 0.9)
        settle(a, rate: rate)
        settle(b, rate: rate)
        let impulse: [Float] = [0.01] + Array(repeating: 0, count: 1023)
        let left = process(a, [impulse])[0]
        let right = process(b, [impulse])[0]
        #expect(zip(left, right).allSatisfy { abs($0 - $1) < 1e-6 })
    }
    var routing = mb_routing()
    routing.input_count = 2
    #expect(mb_engine_configure(a, &routing) == 0)
    mb_engine_set_channel_mode(a, MB_STEREO, 0)
    mb_engine_set_eq_enabled(a, false)
    mb_engine_set_gain_db(a, 24)
    settle(a, rate: rate)
    let linked = process(a, [Array(repeating: 0.5, count: 256), Array(repeating: 0.05, count: 256)])
    #expect(zip(linked[0], linked[1]).allSatisfy { abs($0 - 10 * $1) < 1e-6 })
}

@Test(arguments: rates) func abruptMidAndFullBypass(rate: Double) throws {
    let engine = try #require(mb_engine_create(32, rate))
    defer { mb_engine_destroy(engine) }
    var last: Float = 0
    var offset = 0
    for (frequency, gain, q) in [(200.0, 12.0, 4.0), (6000, -12, 0.3), (1000, 0, 0.9)] {
        mb_engine_set_band(engine, MB_MID, Float(frequency), Float(gain), Float(q))
        let input = (offset..<offset + Int(rate * 0.1)).map {
            Float(0.005 * sin(2 * .pi * 440 * Double($0) / rate))
        }
        for sample in process(engine, [input])[0] {
            #expect(abs(sample - last) < 0.01)
            last = sample
        }
        offset += input.count
    }
    for (band, frequency) in [(MB_LOW, Float(120)), (MB_MID, 1000), (MB_HIGH, 6000)] {
        mb_engine_set_band(engine, band, frequency, 12, 0.9)
    }
    settle(engine, rate: rate)
    mb_engine_set_eq_enabled(engine, false)
    _ = process(engine, [Array(repeating: 0.01, count: Int(rate * 0.020) + 1)])
    #expect(abs(process(engine, [[0.01]])[0][0] - 0.01) < 1e-6)
}
