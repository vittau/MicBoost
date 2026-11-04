import AppKit
import SwiftUI

/// Slider for the status item panel. SwiftUI's `Slider` tracks a drag with its own gesture
/// recognizer, and the menu tracking loop owns the events: a drag released outside the
/// hosted view never delivers its mouse-up, leaving the slider pressed, stuck at the last
/// position and ignoring the mouse. `NSSlider` runs its own mouse-tracking loop, so it keeps
/// working inside the menu, like the system volume menu.
@MainActor struct MenuSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    /// One arrow-key press moves the value by `step`, or by `optionStep` with Option held.
    var step: Double
    var optionStep: Double
    var label: String
    var valueText: String
    /// Writes through the binding; the model keeps quantization and clamping.
    var onEdit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MenuSliderControl {
        let slider = MenuSliderControl(frame: .zero)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.isContinuous = true
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        return slider
    }

    func updateNSView(_ slider: MenuSliderControl, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.step = step
        slider.optionStep = optionStep
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValue(valueText)
        slider.reflect(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuSliderControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: nsView.intrinsicContentSize.height)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: MenuSlider

        init(_ parent: MenuSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) { parent.onEdit(sender.doubleValue) }
    }
}

/// Native slider with an explicit tracking flag, so a value that comes from elsewhere never
/// moves the knob mid-drag.
@MainActor final class MenuSliderControl: NSSlider {
    var step = 0.5
    var optionStep = 1.0
    /// Set for the duration of a drag; tests set it to cover the drag path.
    var isTrackingKnob = false

    override func mouseDown(with event: NSEvent) {
        isTrackingKnob = true
        super.mouseDown(with: event)
        isTrackingKnob = false
    }

    /// Shows the value the model accepted, quantized and clamped, unless the user is dragging.
    func reflect(_ value: Double) {
        guard !isTrackingKnob, doubleValue != value else { return }
        doubleValue = value
    }

    override func keyDown(with event: NSEvent) {
        let delta = event.modifierFlags.contains(.option) ? optionStep : step
        switch event.keyCode {
        case 123, 125: adjust(-delta)  // left and down
        case 124, 126: adjust(delta)  // right and up
        default: super.keyDown(with: event)
        }
    }

    private func adjust(_ delta: Double) {
        doubleValue = min(maxValue, max(minValue, doubleValue + delta))
        sendAction(action, to: target)
    }
}
