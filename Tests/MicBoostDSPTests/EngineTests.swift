import CoreAudio
import MicBoostDSP
import Testing

func process(_ engine: OpaquePointer, _ channels: [[Float]]) -> [[Float]] {
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

@Test func ioProcZerosPhysicalOutputsAndHandlesMissingInput() throws {
    let engine = try #require(mb_engine_create(2, 48000))
    defer { mb_engine_destroy(engine) }
    var routing = mb_routing()
    routing.input_count = 1
    routing.outputs.0 = mb_channel(buffer: 1, channel: 0)
    routing.outputs.1 = mb_channel(buffer: 1, channel: 1)
    #expect(mb_engine_configure(engine, &routing) == 0)
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride,
        alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(
        as: UInt8.self, repeating: 0,
        count: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride)
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    list.pointee.mNumberBuffers = 2
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    var physical: [Float] = Array(repeating: 1, count: 8)
    var blackHole: [Float] = Array(repeating: 1, count: 8)
    physical.withUnsafeMutableBytes { physicalBytes in
        blackHole.withUnsafeMutableBytes { destinationBytes in
            buffers[0] = AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(physicalBytes.count), mData: physicalBytes.baseAddress)
            buffers[1] = AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(destinationBytes.count), mData: destinationBytes.baseAddress)
            var input = AudioBufferList(
                mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: nil))
            var now = AudioTimeStamp()
            var before = AudioTimeStamp()
            var after = AudioTimeStamp()
            before.mHostTime = 100
            after.mHostTime = 150
            #expect(mb_ioproc(1, &now, &input, &before, list, &after, UnsafeMutableRawPointer(engine)) == 0)
        }
    }
    #expect(physical == Array(repeating: 0, count: 8))
    #expect(blackHole == Array(repeating: 0, count: 8))
    var counters = mb_counters()
    mb_engine_read_counters(engine, &counters)
    #expect(counters.input_missing == 1)
    #expect(counters.cycles == 1)
    #expect(counters.frames_over_max == 1)
    #expect(counters.io_delta_host == 50)
}

@Test func ioProcMonitorCopiesFinalSamplesAndZerosExtraChannels() throws {
    for count: UInt32 in [1, 2] {
        let engine = try #require(mb_engine_create(16, 48000))
        defer { mb_engine_destroy(engine) }
        var routing = mb_routing()
        routing.input_count = 2
        routing.inputs.1 = mb_channel(buffer: 0, channel: 1)
        routing.outputs.0 = mb_channel(buffer: 1, channel: 0)
        routing.outputs.1 = mb_channel(buffer: 1, channel: 1)
        routing.monitor_count = count
        routing.monitor.0 = mb_channel(buffer: 0, channel: 0)
        routing.monitor.1 = mb_channel(buffer: 0, channel: 1)
        #expect(mb_engine_configure(engine, &routing) == 0)
        mb_engine_set_channel_mode(engine, MB_STEREO, 0)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        list.unsafeMutablePointer.pointee.mNumberBuffers = 2
        var source: [Float] = Array(repeating: [Float(0.2), -0.1], count: 16).flatMap { $0 }
        var monitor = Array(repeating: Float(1), count: 48)
        var blackHole = Array(repeating: Float(1), count: 32)
        for muted in [false, true] {
            mb_engine_set_muted(engine, muted)
            source.withUnsafeMutableBytes { inputBytes in
                monitor.withUnsafeMutableBytes { outputBytes in
                    blackHole.withUnsafeMutableBytes { blackHoleBytes in
                        list[0] = AudioBuffer(
                            mNumberChannels: 3, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress
                        )
                        list[1] = AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(blackHoleBytes.count),
                            mData: blackHoleBytes.baseAddress)
                        var input = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(
                                mNumberChannels: 2, mDataByteSize: UInt32(inputBytes.count),
                                mData: inputBytes.baseAddress))
                        var time = AudioTimeStamp()
                        var before = AudioTimeStamp()
                        var after = AudioTimeStamp()
                        #expect(
                            mb_ioproc(
                                1, &time, &input, &before, list.unsafeMutablePointer, &after,
                                UnsafeMutableRawPointer(engine)) == 0)
                    }
                }
            }
            for i in 0..<16 {
                #expect(
                    monitor[i * 3] == (count == 1 ? (blackHole[i * 2] + blackHole[i * 2 + 1]) / 2 : blackHole[i * 2]))
                #expect(monitor[i * 3 + 1] == (count == 1 ? 0 : blackHole[i * 2 + 1]))
                #expect(monitor[i * 3 + 2] == 0)
            }
        }
    }
}
