import AppKit
import SwiftUI

/// Audio peaks are instantaneous levels, not animated task completion.
@MainActor struct LevelMeterView: NSViewRepresentable {
    var fraction: Double

    func makeNSView(context: Context) -> NSLevelIndicator {
        let indicator = NSLevelIndicator()
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.isEditable = false
        return indicator
    }

    func updateNSView(_ indicator: NSLevelIndicator, context: Context) {
        indicator.fillColor = .controlAccentColor
        indicator.warningFillColor = .controlAccentColor
        indicator.criticalFillColor = .controlAccentColor
        indicator.doubleValue = fraction
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSLevelIndicator, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 6)
    }
}
