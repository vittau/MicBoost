import AppKit

/// Native slider with an explicit tracking flag, so a value that comes from elsewhere never
/// moves the knob mid-drag. `NSSlider` runs its own mouse-tracking loop, so it keeps working
/// inside the menu, like the system volume menu.
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

/// Numeric field of a menu row. The typed text is kept as it is until the user commits with
/// Return, Tab, focus loss or the menu closing: empty or partial input stays visible and is
/// never rejected by a formatter, so a value can be cleared and replaced (docs/ui.md
/// "Teclado e acessibilidade").
@MainActor final class MenuNumberField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((Double) -> Void)?
    var onArrowStep: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var shownValue: Double?
    private var fractionDigits = 1
    /// The field editor holds the text; model updates must not overwrite it.
    var isEditingText = false

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .small
        font = .menuFont(ofSize: 0)
        alignment = .right
        delegate = self
        target = self
        action = #selector(commitAction)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Comma or dot decimal, whichever the user typed (docs/ui.md "Teclado e acessibilidade").
    nonisolated static func parse(_ text: String, locale: Locale) -> Double? {
        var normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }
        if locale.decimalSeparator == "," {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        normalized = normalized.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    nonisolated static func format(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...fractionDigits)).grouping(.never))
    }

    func show(_ value: Double, fractionDigits: Int) {
        shownValue = value
        self.fractionDigits = fractionDigits
        guard !isEditingText else { return }
        stringValue = Self.format(value, fractionDigits: fractionDigits, locale: .current)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        isEditingText = true
        selectText(nil)
        if let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
        }
        return accepted
    }

    @objc private func commitAction() { commit() }

    private func commit() {
        guard isEditingText else { return }
        isEditingText = false
        guard let value = Self.parse(stringValue, locale: .current) else {
            restoreShownValue()
            return
        }
        onCommit?(value)
    }

    private func cancel() {
        guard isEditingText else { return }
        isEditingText = false
        restoreShownValue()
        onCancel?()
    }

    private func restoreShownValue() {
        guard let shownValue else { return }
        stringValue = Self.format(shownValue, fractionDigits: fractionDigits, locale: .current)
    }

    func controlTextDidEndEditing(_ notification: Notification) { commit() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onArrowStep?(1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onArrowStep?(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
