import AppKit
import SwiftUI

/// Audio peaks are instantaneous levels, not animated task completion.
@MainActor struct LevelMeterView: NSViewRepresentable {
    var fraction: Double

    func makeNSView(context: Context) -> LevelMeterIndicator {
        let indicator = LevelMeterIndicator()
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.levelIndicator)
        return indicator
    }

    func updateNSView(_ indicator: LevelMeterIndicator, context: Context) {
        indicator.fraction = fraction
        indicator.setAccessibilityValue(fraction)
        indicator.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelMeterIndicator, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 6)
    }
}

/// Keep read-only level semantics while drawing the system slider track at its native height.
@MainActor final class LevelMeterIndicator: NSControl {
    var fraction = 0.0
    private let track = NSSliderCell()

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        track.minValue = 0
        track.maxValue = 1
        track.doubleValue = fraction
        track.drawBar(inside: bounds, flipped: isFlipped)
    }
}
