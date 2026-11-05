/// AUHAL render host time is the scheduled output time, not callback invocation time.
/// Add processing latency only; another IO buffer would count the same schedule twice.
public enum MonitorLatency {
    public static func preferredBufferFrames(
        engineFrames: UInt32, engineRate: Double, outputRate: Double, range: AudioRange
    ) -> UInt32 {
        let frames = max(1, (Double(engineFrames) * outputRate / engineRate).rounded())
        return UInt32(
            range.minimum > 0 && range.maximum >= range.minimum
                ? min(range.maximum, max(range.minimum, frames)) : frames)
    }
    public static func addedMilliseconds(hostMilliseconds: Double, varispeedSeconds: Double, auhalSeconds: Double)
        -> Double
    {
        hostMilliseconds + 1000 * (varispeedSeconds + auhalSeconds)
    }
}
