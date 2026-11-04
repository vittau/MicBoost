import AppKit

/// Native slider with an explicit tracking flag, so a value that comes from elsewhere never
/// moves the knob mid-drag. `NSSlider` runs its own mouse-tracking loop, so it keeps working
/// inside the menu, like the system volume menu.
@MainActor final class MenuSliderControl: NSSlider {
    var step = 0.5
    var optionStep = 1.0
    /// Arrow-key step of a control whose values are not evenly spaced (the logarithmic
    /// frequency sliders): returns the value the knob should take for a direction, instead of
    /// adding `step` to the current value.
    var steppedValue: ((_ direction: Int, _ option: Bool) -> Double)?
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
        switch event.keyCode {
        case 123, 125: adjust(-1, event)  // left and down
        case 124, 126: adjust(1, event)  // right and up
        default: super.keyDown(with: event)
        }
    }

    private func adjust(_ direction: Int, _ event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        let next: Double
        if let steppedValue {
            next = steppedValue(direction, option)
        } else {
            next = doubleValue + Double(direction) * (option ? optionStep : step)
        }
        doubleValue = min(maxValue, max(minValue, next))
        sendAction(action, to: target)
    }
}

/// Peaks are a level, and `NSLevelIndicator` is the system control for one: it keeps the tint,
/// height and bezel of the current macOS instead of drawing a track of our own (docs/ui.md
/// "Medidores na UI").
@MainActor final class LevelMeterIndicator: NSLevelIndicator {
    override init(frame: NSRect) {
        super.init(frame: frame)
        levelIndicatorStyle = .continuousCapacity
        controlSize = .small
        // The bar is filled by the amplitude (docs/ui.md "Medidores na UI"), so the value is
        // the fraction of the full scale. The bar never turns yellow or red: the app already
        // keeps the peak ceiling and the panel does not warn about saturation.
        minValue = 0
        maxValue = 1
        warningValue = 2
        criticalValue = 2
        isEditable = false
        refusesFirstResponder = true
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        applyTint()
        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTint() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A meter is a display, not a control: mouse-downs and drags belong to the row, and the
    /// meter never takes the keyboard focus (docs/ui.md "Medidores na UI").
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    private var colorObserver: (any NSObjectProtocol)?

    /// The bar follows the accent color of the system, like the other controls
    /// (docs/ui.md "Medidores na UI").
    private func applyTint() {
        fillColor = .controlAccentColor
        warningFillColor = .controlAccentColor
        criticalFillColor = .controlAccentColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    func show(_ db: Double) {
        let amplitude = db.isFinite ? min(1, max(0, pow(10, min(0, db) / 20))) : 0
        if doubleValue != amplitude { doubleValue = amplitude }
        let level = db.isFinite ? min(0, max(-60, db)) : -60
        setAccessibilityValue("\(Int(level.rounded())) dBFS")
    }
}
