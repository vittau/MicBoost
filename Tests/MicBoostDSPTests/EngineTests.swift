import MicBoostDSP
import Testing

private func process(_ engine: OpaquePointer, _ channels: [[Float]]) -> [[Float]] {
    let count = channels.first?.count ?? 0
    let inputs = channels.map { values -> UnsafeMutablePointer<Float> in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(from: values, count: count)
        return pointer
    }
    defer { for pointer in inputs { pointer.deallocate() } }
    let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
    defer {
        left.deallocate()
        right.deallocate()
    }
    var pointers = inputs.map { Optional(UnsafePointer($0)) }
    var outputs: [UnsafeMutablePointer<Float>?] = [left, right]
    pointers.withUnsafeMutableBufferPointer { input in
        outputs.withUnsafeMutableBufferPointer { output in
            if let i = input.baseAddress, let o = output.baseAddress { mb_engine_process(engine, i, o, UInt32(count)) }
        }
    }
    return [
        Array(UnsafeBufferPointer(start: left, count: count)), Array(UnsafeBufferPointer(start: right, count: count)),
    ]
}
@Test func channelModesAndLargeBlocks() throws {
    let engine = try #require(mb_engine_create(16, 48000))
    defer { mb_engine_destroy(engine) }
    var routing = mb_routing()
    routing.input_count = 2
    #expect(mb_engine_configure(engine, &routing) == 0)
    let a = (0..<257).map { Float($0) / 1024 }
    let b = a.map { -$0 }
    for (mode, first, expected) in [
        (MB_AUTO, UInt32(0), [a, a]), (MB_MONO, 1, [b, b]),
        (MB_MONO_MIX, 0, [Array(repeating: Float(0), count: 257), Array(repeating: Float(0), count: 257)]),
        (MB_STEREO, 0, [a, b]),
    ] {
        mb_engine_set_channel_mode(engine, mode, first)
        let output = process(engine, [a, b])
        #expect(output.map { $0.map(\.bitPattern) } == expected.map { $0.map(\.bitPattern) })
    }
    var counters = mb_counters()
    mb_engine_read_counters(engine, &counters)
    #expect(counters.frames_over_max == 4)
    #expect(counters.cycles == 4)
}
@Test func fadeAndMetersExchange() throws {
    let engine = try #require(mb_engine_create(64, 48000))
    defer { mb_engine_destroy(engine) }
    _ = process(engine, [[0.5, -0.25]])
    var meters = mb_meters()
    mb_engine_read_meters(engine, &meters)
    #expect(meters.input_peak == 0.5)
    #expect(meters.output_peak == 0.5)
    mb_engine_read_meters(engine, &meters)
    #expect(meters.input_peak == 0 && meters.output_peak == 0)
    mb_engine_begin_fade_out(engine)
    let output = process(engine, [Array(repeating: 0.5, count: 2400)])[0]
    #expect(output.last == 0)
    #expect(zip(output, output.dropFirst()).allSatisfy { $0 >= $1 })
    mb_engine_read_meters(engine, &meters)
    #expect(meters.fade_done)
}
@Test func nonfiniteGuard() throws {
    let engine = try #require(mb_engine_create(4, 48000))
    defer { mb_engine_destroy(engine) }
    let output = process(engine, [[.nan, .infinity, -.infinity, 0.125]])
    #expect(output.flatMap { $0 }.allSatisfy { $0.isFinite })
    #expect(output[0] == [0, 0, 0, 0.125])
    var counters = mb_counters()
    mb_engine_read_counters(engine, &counters)
    #expect(counters.nonfinite_resets == 1)
}
