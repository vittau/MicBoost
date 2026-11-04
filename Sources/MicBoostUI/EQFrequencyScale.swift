import Foundation

/// Frequency axis of the equalizer sliders: a logarithmic scale over the range of the band,
/// bounded by the effective maximum of the current sample rate, and the value grid of
/// docs/dsp.md "Equalizador". The grid changes step with the frequency, so a value near a
/// boundary rounds to the nearest grid value of its own tier, which keeps the grid continuous
/// (195 Hz → 200 Hz, 950 Hz → 1000 Hz, 9750 Hz → 10000 Hz).
enum EQFrequencyScale {
    /// Grid step at `frequency`, in Hz (docs/dsp.md "Equalizador").
    static func gridStep(for frequency: Double) -> Double {
        switch frequency {
        case ..<200: return 10
        case ..<1000: return 100
        case ..<10000: return 500
        default: return 1000
        }
    }

    /// Snaps a frequency to the grid. Halfway values round up, so even a lower tier boundary
    /// (199 Hz, 999 Hz, 9999 Hz) lands on the next tier's first value.
    static func quantized(_ frequency: Double) -> Double {
        guard frequency.isFinite, frequency > 0 else { return frequency }
        let step = gridStep(for: frequency)
        return (frequency / step).rounded() * step
    }

    /// Position of a frequency on the logarithmic scale of `range`, from 0 at its lower bound
    /// to 1 at its upper bound.
    static func position(of frequency: Double, in range: ClosedRange<Double>) -> Double {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper > lower, lower > 0 else { return 0 }
        let hz = min(max(frequency, lower), upper)
        return log(hz / lower) / log(upper / lower)
    }

    /// Frequency of a logarithmic position in `range`, the inverse of `position(of:in:)`.
    static func frequency(at position: Double, in range: ClosedRange<Double>) -> Double {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper > lower else { return lower }
        return lower * pow(upper / lower, min(max(position, 0), 1))
    }

    /// Next grid value above `frequency`, or nil when no grid value fits before the top.
    private static func gridValue(after frequency: Double) -> Double? {
        let snapped = quantized(frequency)
        if snapped > frequency { return snapped }
        return snapped + gridStep(for: snapped)
    }

    /// Previous grid value below `frequency`, or nil when no grid value fits before the bottom.
    private static func gridValue(before frequency: Double) -> Double? {
        let snapped = quantized(frequency)
        if snapped < frequency { return snapped }
        // At a tier boundary the step below is smaller than the step of the value itself.
        return snapped - gridStep(for: snapped.nextDown)
    }

    /// Frequency the arrow keys move to: the next or previous grid value strictly beyond the
    /// current one. At the ends of the range the value only snaps to the grid.
    static func stepped(from frequency: Double, by direction: Int, in range: ClosedRange<Double>) -> Double {
        guard direction != 0 else { return frequency }
        let bounded = min(max(frequency, range.lowerBound), range.upperBound)
        let target = direction < 0 ? gridValue(before: bounded) : gridValue(after: bounded)
        if let target, range.contains(target) { return target }
        return min(max(quantized(bounded), range.lowerBound), range.upperBound)
    }
}
