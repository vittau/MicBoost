import CoreAudio
import Testing
import MicBoostDSP
@Test func captureAllocation() {
    #expect(mb_capture_create(0, 1) == nil)
    let buffer = mb_capture_create(256, 2)
    #expect(buffer != nil)
    if let buffer { #expect(mb_capture_frames(buffer) == 0); mb_capture_destroy(buffer) }
}
@Test func captureCopiesAndBoundsFrames() throws {
    let capture = try #require(mb_capture_create(2, 2))
    defer { mb_capture_destroy(capture) }
    var input: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
    input.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        var output = AudioBufferList(); var time = AudioTimeStamp(); var inputTime = AudioTimeStamp(); var outputTime = AudioTimeStamp()
        #expect(mb_capture_ioproc(1, &time, &list, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(capture)) == 0)
    }
    #expect(mb_capture_frames(capture) == 2)
    let samples = mb_capture_samples(capture)
    #expect(samples[0] == 0.1); #expect(samples[3] == -0.4)
}
