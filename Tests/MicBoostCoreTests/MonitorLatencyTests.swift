import Testing

@testable import MicBoostCore

@Test func monitorFormulaDoesNotAddOutputBufferToScheduledHostTime() {
    // Scheduled host delta already includes when the HAL will deliver the buffer.
    let actual = MonitorLatency.addedMilliseconds(hostMilliseconds: 30, varispeedSeconds: 0.001, auhalSeconds: 0.002)
    #expect(actual == 33)
    let oldWithBuffer = actual + 512.0 / 44100 * 1000
    #expect(abs((oldWithBuffer - actual) - 11.6099773243) < 0.000001)
}
@Test func monitorBufferPreferenceUsesDurationAndClampsToReportedRange() {
    #expect(
        MonitorLatency.preferredBufferFrames(
            engineFrames: 256, engineRate: 48000, outputRate: 44100, range: .init(256, 2048)) == 256)
    #expect(
        MonitorLatency.preferredBufferFrames(
            engineFrames: 256, engineRate: 48000, outputRate: 44100, range: .init(64, 2048)) == 235)
}
