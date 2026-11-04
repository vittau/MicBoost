import AppKit
import MicBoostCore

/// Base of every custom row of the status menu: a view-based `NSMenuItem` whose content is an
/// AppKit stack view, inset like a native `NSMenuItem` title (docs/ui.md "Painel").
@MainActor class PanelMenuRow: NSView {
    static let defaultWidth = MenuMetrics.contentWidth

    let stack = NSStackView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!
    var verticalPadding: CGFloat
    /// Rows nested in another row (the equalizer bands) must not repeat the menu insets.
    private let appliesInsets: Bool

    init(spacing: CGFloat = 4, verticalPadding: CGFloat = 3, insets: Bool = true) {
        self.verticalPadding = verticalPadding
        appliesInsets = insets
        super.init(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 24))
        autoresizingMask = [.width]
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        leading = stack.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: insets ? MenuMetrics.titleInset : 0)
        trailing = stack.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: insets ? -MenuMetrics.trailingInset : 0)
        top = stack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding)
        bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding)
        NSLayoutConstraint.activate([leading, trailing, top, bottom])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adopts the insets measured from the open menu and the height of the content.
    func applyMetrics() {
        leading.constant = appliesInsets ? MenuMetrics.titleInset : 0
        trailing.constant = appliesInsets ? -MenuMetrics.trailingInset : 0
        top.constant = verticalPadding
        bottom.constant = -verticalPadding
        updateHeight()
    }

    /// The menu row is as tall as its content; the menu sizes the item from this frame.
    func updateHeight() {
        let width = frame.width > 0 ? frame.width : Self.defaultWidth
        layoutSubtreeIfNeeded()
        let height = max(20, fittingSize.height)
        guard frame.height != height || frame.width != width else { return }
        setFrameSize(NSSize(width: width, height: height))
        needsLayout = true
    }

    func addRow(_ view: NSView, fullWidth: Bool = true) {
        stack.addArrangedSubview(view)
        if fullWidth {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    static func horizontal(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func spacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    static var menuFont: NSFont { .menuFont(ofSize: 0) }
    static var boldFont: NSFont {
        NSFontManager.shared.convert(menuFont, toHaveTrait: .boldFontMask)
    }
    static var captionFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }

    static func label(
        _ text: String, font: NSFont = PanelMenuRow.captionFont, color: NSColor = .secondaryLabelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}

/// A rounded, filled background for the banner and the limiter badge. `NSBox` provides the
/// fill; nothing is drawn by the app (docs/ui.md "Painel").
@MainActor final class PanelPill: NSBox {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        boxType = .custom
        borderWidth = 0
        fillColor = .quaternarySystemFill
        cornerRadius = radius
        contentViewMargins = .zero
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func hold(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(view)
        guard let content = contentView else { return }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}

/// A microphone of the list, as Apple draws device rows in menu bar extras: the transport
/// symbol in a circular badge, filled with the accent color when the device is selected, then
/// the name. The row is a view-based item and does not paint a background, so the menu's own
/// hover highlight shows through (docs/ui.md "Painel", item 5).
@MainActor final class PanelMicrophoneRow: NSView {
    private let badge = PanelBadgeView()
    private let name = PanelMenuRow.label(
        "", font: .menuFont(ofSize: 0), color: .labelColor)
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.contentWidth, height: 24))
        autoresizingMask = [.width]
        badge.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(name)
        leading = badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.titleInset)
        trailing = name.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailingInset)
        NSLayoutConstraint.activate([
            leading, trailing,
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyMetrics() {
        leading.constant = MenuMetrics.titleInset
        trailing.constant = -MenuMetrics.trailingInset
    }

    func update(name: String, symbol: String, selected: Bool) {
        self.name.stringValue = name
        badge.update(symbol: symbol, selected: selected)
        textColor()
        setAccessibilityLabel(name)
        setAccessibilityValue(selected ? localized("Selected") : "")
        setAccessibilitySelected(selected)
    }

    /// The menu draws the highlight; the row only follows the highlighted item's text color,
    /// like a native item does (docs/ui.md "Painel", item 5).
    override func draw(_ dirtyRect: NSRect) {
        textColor()
        super.draw(dirtyRect)
    }

    /// A view-based menu item gets no action from the menu on a click, so the row performs
    /// its item's action itself and closes the menu, as a native item does.
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }

    private func textColor() {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        name.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
    }
}

/// Circular device badge: accent fill when the device is selected, neutral otherwise, with the
/// transport symbol inside.
@MainActor final class PanelBadgeView: NSView {
    private let image = NSImageView()
    private var selected = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 11),
            image.heightAnchor.constraint(equalToConstant: 11),
        ])
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(symbol: String, selected: Bool) {
        self.selected = selected
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        layer?.backgroundColor =
            (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        image.contentTintColor = selected ? .white : .labelColor
    }
}

/// Header: the panel title and the processing switch, in the layout of the Wi-Fi and Bluetooth
/// menu headers (docs/ui.md "Painel", item 1).
@MainActor final class PanelHeaderRow: PanelMenuRow {
    let toggle = NSSwitch()
    private let title = PanelMenuRow.label(
        localized("MicBoost"), font: PanelMenuRow.boldFont, color: .labelColor)

    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(spacing: 0, verticalPadding: 2)
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(localized("Processing"))
        addRow(PanelMenuRow.horizontal([title, PanelMenuRow.spacer(), toggle]))
        updateHeight()
    }

    @objc private func toggled() { onToggle?(toggle.state == .on) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(enabled: Bool) {
        toggle.state = enabled ? .on : .off
        toggle.setAccessibilityValue(localized(enabled ? "On" : "Off"))
    }
}

/// Status banner (docs/ui.md "Mensagens de estado").
@MainActor final class PanelBannerRow: PanelMenuRow {
    private let icon = NSImageView()
    private let message = PanelMenuRow.label("", font: .systemFont(ofSize: 11), color: .labelColor)
    private let actionRow = NSStackView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private let pill = PanelPill(radius: 8)
    private var lastAction: AppModel.StatusMessage.Action = .noAction

    var onAction: ((AppModel.StatusMessage.Action) -> Void)?

    init() {
        super.init(spacing: 4, verticalPadding: 6)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemYellow
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        message.preferredMaxLayoutWidth = Self.defaultWidth - 2 * MenuMetrics.titleInset - 24
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(runAction)
        actionRow.addArrangedSubview(button)
        actionRow.addArrangedSubview(PanelMenuRow.spacer())
        let text = PanelMenuRow.horizontal([icon, message])
        let content = NSStackView(views: [text, actionRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        pill.hold(content)
        addRow(pill)
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ message: String?, action: AppModel.StatusMessage.Action) {
        guard let message else { return }
        self.message.stringValue = message
        lastAction = action
        // The documentation links read as accent text, like the other links of a menu bar
        // panel; the retry keeps the bordered button of an action.
        switch action {
        case .privacySettings:
            button.title = localized("Open Privacy Settings")
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
        case .install:
            button.title = localized("How to install")
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
        case .retry:
            button.title = localized("Try again")
            button.isBordered = true
            button.bezelStyle = .rounded
            button.contentTintColor = nil
        case .noAction:
            button.title = ""
        }
        button.isHidden = action == .noAction
        updateHeight()
    }

    @objc private func runAction() {
        onAction?(lastAction)
    }
}

/// Gain row: the mute button, the native slider, the read-only gain label and the limiter badge
/// (docs/ui.md "Painel", item 3).
@MainActor final class PanelGainRow: PanelMenuRow {
    let mute = NSButton()
    let slider = MenuSliderControl(frame: .zero)
    private let value = PanelMenuRow.label(
        "", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .labelColor)
    private let badge = PanelPill(radius: 8)
    private let badgeLabel = PanelMenuRow.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

    var onMute: (() -> Void)?
    var onGain: ((Double) -> Void)?

    init() {
        super.init(spacing: 2, verticalPadding: 3)
        mute.isBordered = false
        mute.bezelStyle = .regularSquare
        mute.imagePosition = .imageOnly
        mute.imageScaling = .scaleProportionallyDown
        mute.target = self
        mute.action = #selector(toggleMute)
        mute.setAccessibilityLabel(localized("Mute"))
        mute.toolTip = localized("Mute")
        mute.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mute.widthAnchor.constraint(equalToConstant: 20), mute.heightAnchor.constraint(equalToConstant: 20),
        ])
        slider.target = self
        slider.action = #selector(gainChanged)
        slider.isContinuous = true
        slider.minValue = Settings.gainRange.lowerBound
        slider.maxValue = Settings.gainRange.upperBound
        slider.step = AppModel.gainStep(option: false)
        slider.optionStep = AppModel.gainStep(option: true)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(localized("Gain"))

        value.setAccessibilityLabel(localized("Gain"))

        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badge.setAccessibilityLabel(localized("Limiter active"))
        badgeStack()

        let sliderRow = PanelMenuRow.horizontal([mute, slider])
        let valueRow = PanelMenuRow.horizontal([value, PanelMenuRow.spacer(), badge])
        addRow(sliderRow)
        addRow(valueRow)
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func badgeStack() {
        let holder = NSStackView(views: [badgeLabel])
        holder.orientation = .horizontal
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        badge.hold(holder)
    }

    @objc private func toggleMute() { onMute?() }

    @objc private func gainChanged() { onGain?(slider.doubleValue) }

    func update(gainDB: Double, muted: Bool, limiting: Bool) {
        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        mute.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mute.setAccessibilityValue(localized(muted ? "On" : "Off"))
        slider.reflect(gainDB)
        slider.setAccessibilityValue(AppModel.gainLabel(gainDB))
        value.stringValue = AppModel.gainLabel(gainDB)
        badge.isHidden = !limiting
    }
}

/// Input and output meters (docs/ui.md "Medidores na UI").
@MainActor final class PanelMetersRow: PanelMenuRow {
    private let input = LevelMeterIndicator(frame: .zero)
    private let output = LevelMeterIndicator(frame: .zero)
    private let inputLabel = PanelMenuRow.label(localized("Input"))
    private let outputLabel = PanelMenuRow.label(localized("Output"))

    init() {
        super.init(spacing: 4, verticalPadding: 4)
        inputLabel.setAccessibilityLabel(localized("Input"))
        outputLabel.setAccessibilityLabel(localized("Output"))
        input.translatesAutoresizingMaskIntoConstraints = false
        output.translatesAutoresizingMaskIntoConstraints = false
        inputLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        outputLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        addRow(PanelMenuRow.horizontal([inputLabel, input]))
        addRow(PanelMenuRow.horizontal([outputLabel, output]))
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(inputDB: Double, outputDB: Double) {
        input.show(inputDB)
        output.show(outputDB)
    }
}

/// Routing row: the system input and the "Use MicBoost" action (docs/ui.md "Painel", item 4).
@MainActor final class PanelRoutingRow: PanelMenuRow {
    private let check = NSImageView()
    private let label = PanelMenuRow.label("")
    private let button = NSButton(title: localized("Use MicBoost"), target: nil, action: nil)
    private let buttonRow = NSStackView()

    var onUseMicBoost: (() -> Void)?

    init() {
        super.init(spacing: 3, verticalPadding: 4)
        label.font = PanelMenuRow.captionFont
        label.textColor = .secondaryLabelColor
        check.translatesAutoresizingMaskIntoConstraints = false
        check.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(useMicBoost)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(PanelMenuRow.spacer())
        buttonRow.addArrangedSubview(button)
        addRow(PanelMenuRow.horizontal([check, label]))
        addRow(buttonRow)
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func useMicBoost() { onUseMicBoost?() }

    func update(_ routing: AppModel.Routing) {
        if routing.isBlackHole {
            label.stringValue = localized("System input: MicBoost")
            check.image =
                routing.running
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) : nil
            check.isHidden = !routing.running
        } else {
            label.stringValue = "\(localized("System input")): \(routing.name ?? localized("Unknown"))"
            check.image = nil
            check.isHidden = true
        }
        button.isHidden = routing.isBlackHole || routing.name == nil
        button.isEnabled = routing.canUseMicBoost
        check.setAccessibilityLabel(routing.isBlackHole ? localized("System input: MicBoost") : nil)
        updateHeight()
    }
}

/// Header of the equalizer section: a native disclosure control with the "Enable EQ" switch
/// (docs/ui.md "Painel", item 6).
@MainActor final class PanelEQHeaderRow: PanelMenuRow {
    private let disclosure = NSButton()
    private let title = NSButton(title: localized("Equalizer"), target: nil, action: nil)
    private let toggle = NSSwitch()

    var onDisclose: (() -> Void)?
    var onEnable: ((Bool) -> Void)?

    init() {
        super.init(spacing: 0, verticalPadding: 2)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(disclose)
        disclosure.setAccessibilityLabel(localized("Equalizer"))
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        title.isBordered = false
        title.bezelStyle = .inline
        title.font = PanelMenuRow.boldFont
        title.contentTintColor = .labelColor
        title.alignment = .left
        title.target = self
        title.action = #selector(disclose)
        title.setAccessibilityLabel(localized("Equalizer"))
        title.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(enabledChanged)
        toggle.setAccessibilityLabel(localized("Enable EQ"))
        addRow(PanelMenuRow.horizontal([disclosure, title, PanelMenuRow.spacer(), toggle], spacing: 4))
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func disclose() { onDisclose?() }

    @objc private func enabledChanged() { onEnable?(toggle.state == .on) }

    func update(expanded: Bool, enabled: Bool) {
        disclosure.state = expanded ? .on : .off
        toggle.state = enabled ? .on : .off
        toggle.setAccessibilityValue(localized(enabled ? "On" : "Off"))
    }
}

/// One equalizer band and its actions (docs/ui.md "Painel", item 6).
@MainActor final class PanelEQBandsRow: PanelMenuRow {
    private let low = PanelBandRow(band: .low)
    private let mid = PanelBandRow(band: .mid)
    private let high = PanelBandRow(band: .high)
    private let preset = NSButton(title: localized("Voice preset"), target: nil, action: nil)
    private let reset = NSButton(title: localized("Reset EQ"), target: nil, action: nil)

    var onGain: ((EQBand, Double) -> Void)?
    var onFrequency: ((EQBand, Double) -> Void)?
    var onWidth: ((Double) -> Void)?
    var onPreset: (() -> Void)?
    var onReset: (() -> Void)?

    init() {
        super.init(spacing: 6, verticalPadding: 6)
        for band in [low, mid, high] {
            band.onGain = { [weak self, band] value in self?.onGain?(band.band, value) }
            band.onFrequency = { [weak self, band] value in self?.onFrequency?(band.band, value) }
            band.onWidth = { [weak self] value in self?.onWidth?(value) }
            addRow(band)
        }
        for button in [preset, reset] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        preset.target = self
        preset.action = #selector(applyPreset)
        reset.target = self
        reset.action = #selector(applyReset)
        addRow(PanelMenuRow.horizontal([preset, PanelMenuRow.spacer(), reset]))
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func applyPreset() { onPreset?() }

    @objc private func applyReset() { onReset?() }

    func update(eq: EQSettings, sampleRate: Double) {
        low.update(gainDB: eq.low.gainDB, frequency: eq.low.frequency, maximum: sampleRate)
        mid.update(gainDB: eq.mid.gainDB, frequency: eq.mid.frequency, maximum: sampleRate, q: eq.mid.q)
        high.update(gainDB: eq.high.gainDB, frequency: eq.high.frequency, maximum: sampleRate)
        updateHeight()
    }
}

/// Controls of a single band: gain, frequency and, for the mid band, width. The frequency is a
/// logarithmic slider over the range of the band, and its value is read-only text like the
/// gain (docs/ui.md "Painel", item 10).
@MainActor final class PanelBandRow: PanelMenuRow {
    let band: EQBand
    private let gainValue = PanelMenuRow.label(
        "", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular))
    private let slider = MenuSliderControl(frame: .zero)
    private let frequencyValue = PanelMenuRow.label(
        "", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular))
    private let frequencySlider = MenuSliderControl(frame: .zero)
    private let widthValue = PanelMenuRow.label(
        "", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular))
    private let width = MenuSliderControl(frame: .zero)
    private var maximum = 20000.0
    private var frequencyRange = EQSettings.lowFrequencyRange
    private var currentFrequency = 0.0

    var onGain: ((Double) -> Void)?
    var onFrequency: ((Double) -> Void)?
    var onWidth: ((Double) -> Void)?

    init(band: EQBand) {
        self.band = band
        super.init(spacing: 4, verticalPadding: 0, insets: false)
        let title = PanelMenuRow.label(Self.title(band), font: PanelMenuRow.boldFont, color: .labelColor)
        title.setAccessibilityRole(.staticText)
        slider.isContinuous = true
        slider.minValue = EQSettings.gainRange.lowerBound
        slider.maxValue = EQSettings.gainRange.upperBound
        slider.step = AppModel.gainStep(option: false)
        slider.optionStep = AppModel.gainStep(option: true)
        slider.target = self
        slider.action = #selector(bandGainChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel("\(Self.title(band)), \(localized("Gain"))")
        frequencySlider.isContinuous = true
        frequencySlider.minValue = 0
        frequencySlider.maxValue = 1
        frequencySlider.target = self
        frequencySlider.action = #selector(frequencyChanged)
        frequencySlider.translatesAutoresizingMaskIntoConstraints = false
        frequencySlider.setAccessibilityLabel("\(Self.title(band)), Hz")
        frequencySlider.steppedValue = { [weak self] direction, _ in
            guard let self else { return 0 }
            let next = EQFrequencyScale.stepped(from: currentFrequency, by: direction, in: frequencyRange)
            return EQFrequencyScale.position(of: next, in: frequencyRange)
        }
        addRow(PanelMenuRow.horizontal([title, PanelMenuRow.spacer(), gainValue]))
        addRow(slider)
        addRow(
            PanelMenuRow.horizontal([
                PanelMenuRow.label(localized("Frequency")), PanelMenuRow.spacer(), frequencyValue,
            ]))
        addRow(frequencySlider)
        if band == .mid {
            width.isContinuous = true
            width.minValue = EQSettings.midQRange.lowerBound
            width.maxValue = EQSettings.midQRange.upperBound
            width.step = 0.1
            width.optionStep = 0.5
            width.target = self
            width.action = #selector(widthChanged)
            width.translatesAutoresizingMaskIntoConstraints = false
            width.setAccessibilityLabel(localized("Width"))
            addRow(
                PanelMenuRow.horizontal([PanelMenuRow.label(localized("Width")), PanelMenuRow.spacer(), widthValue]))
            addRow(width)
        }
        addRow(PanelMenuRow.separator())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func title(_ band: EQBand) -> String {
        switch band {
        case .low: return localized("Bass")
        case .mid: return localized("Mid")
        case .high: return localized("Treble")
        }
    }

    private static func range(_ band: EQBand) -> ClosedRange<Double> {
        switch band {
        case .low: return EQSettings.lowFrequencyRange
        case .mid: return EQSettings.midFrequencyRange
        case .high: return EQSettings.highFrequencyRange
        }
    }

    @objc private func bandGainChanged() {
        let value = (slider.doubleValue * 2).rounded() / 2
        gainValue.stringValue = Self.gainText(value)
        slider.setAccessibilityValue(gainValue.stringValue)
        onGain?(value)
    }

    @objc private func widthChanged() {
        let value = (width.doubleValue * 10).rounded() / 10
        widthValue.stringValue = Self.qText(value)
        width.setAccessibilityValue(widthValue.stringValue)
        onWidth?(value)
    }

    @objc private func frequencyChanged() {
        let hz = EQFrequencyScale.frequency(at: frequencySlider.doubleValue, in: frequencyRange)
        applyFrequency(EQFrequencyScale.quantized(hz))
    }

    /// Shows the frequency the model accepted, clamped to the effective range of the band.
    private func applyFrequency(_ hz: Double) {
        let value = min(frequencyRange.upperBound, max(frequencyRange.lowerBound, hz))
        currentFrequency = value
        frequencyValue.stringValue = Self.frequencyText(value)
        frequencySlider.setAccessibilityValue(frequencyValue.stringValue)
        onFrequency?(value)
    }

    func update(gainDB: Double, frequency hz: Double, maximum sampleRate: Double, q: Double = 0.7) {
        // A frequency above 45% of the sample rate cannot be represented.
        maximum = min(Self.range(band).upperBound, max(Self.range(band).lowerBound, sampleRate * 0.45))
        frequencyRange = Self.range(band).lowerBound...maximum
        gainValue.stringValue = Self.gainText(gainDB)
        slider.reflect(gainDB)
        slider.setAccessibilityValue(gainValue.stringValue)
        let value = min(maximum, max(Self.range(band).lowerBound, hz))
        currentFrequency = value
        frequencyValue.stringValue = Self.frequencyText(value)
        frequencySlider.setAccessibilityValue(frequencyValue.stringValue)
        frequencySlider.reflect(EQFrequencyScale.position(of: value, in: frequencyRange))
        if band == .mid {
            widthValue.stringValue = Self.qText(q)
            width.reflect(q)
            width.setAccessibilityValue(widthValue.stringValue)
        }
    }

    private static func gainText(_ db: Double) -> String {
        let number = db.formatted(
            .number.locale(AppModel.formatLocale).precision(.fractionLength(1)).sign(strategy: .always()))
        return "\(number) dB"
    }

    private static func frequencyText(_ hz: Double) -> String {
        let number = hz.formatted(
            .number.locale(AppModel.formatLocale).precision(.fractionLength(0)).grouping(.never))
        return "\(number) Hz"
    }

    private static func qText(_ q: Double) -> String {
        "Q " + q.formatted(.number.locale(AppModel.formatLocale).precision(.fractionLength(1)))
    }
}

@MainActor final class PanelMonitorRow: PanelMenuRow {
    let toggle = NSSwitch()
    var onToggle: ((Bool) -> Void)?
    init() {
        super.init(spacing: 0, verticalPadding: 2)
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(localized("Hear My Voice"))
        let tip = localized("Use headphones: speakers feed your voice back into the microphone.")
        toggle.toolTip = tip
        toggle.setAccessibilityHelp(tip)
        addRow(
            PanelMenuRow.horizontal([
                PanelMenuRow.label(localized("Hear My Voice"), font: .systemFont(ofSize: 13), color: .labelColor),
                PanelMenuRow.spacer(), toggle,
            ]))
        updateHeight()
    }
    @objc private func toggled() { onToggle?(toggle.state == .on) }
    override func mouseUp(with event: NSEvent) {
        guard toggle.isEnabled else { return }
        toggle.state = toggle.state == .on ? .off : .on
        toggled()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(enabled: Bool, processing: Bool) {
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = processing
    }
}
@MainActor final class PanelMonitorDetailRow: PanelMenuRow {
    private let text = PanelMenuRow.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    init() {
        super.init(spacing: 0, verticalPadding: 2)
        addRow(text)
        updateHeight()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ value: String) { text.stringValue = value }
}
