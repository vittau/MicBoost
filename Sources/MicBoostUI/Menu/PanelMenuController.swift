import AppKit
import CoreAudio
import MicBoostCore

/// The status item panel: a real `NSMenu` built from the model. Actions and the microphone
/// list are native `NSMenuItem`s, and the controls that Apple also hosts in menu bar extras
/// are AppKit views inside view-based items (docs/ui.md "Painel").
/// Real `NSMenu` that also answers the bare-key shortcuts of the panel. The mute shortcut is
/// a hidden menu item (native key-equivalent matching); this override covers menu tracking
/// loops that do not consult hidden items, and stays out of the way of a text field being
/// edited inside a row.
@MainActor final class PanelMenu: NSMenu {
    var onBareKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onBareKey, onBareKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor public final class PanelMenuController: NSObject, NSMenuDelegate {
    public let menu: NSMenu
    private let model: AppModel

    /// Called when the menu opens and closes, so the status item highlights and the meters
    /// start and stop.
    public var onOpen: () -> Void = {}
    public var onClose: () -> Void = {}

    private let headerRow = PanelHeaderRow()
    private let bannerRow = PanelBannerRow()
    private let gainRow = PanelGainRow()
    private let metersRow = PanelMetersRow()
    private let monitorRow = PanelMonitorRow()
    private let monitorDetailRow = PanelMonitorDetailRow()
    private let monitorItem = NSMenuItem()
    private let monitorDetailItem = NSMenuItem()
    private let routingRow = PanelRoutingRow()
    private let equalizerHeaderRow = PanelEQHeaderRow()
    private let equalizerBandsRow = PanelEQBandsRow()

    private let headerItem = NSMenuItem()
    private let bannerItem = NSMenuItem()
    private let gainItem = NSMenuItem()
    private let metersItem = NSMenuItem()
    private let routingItem = NSMenuItem()
    private let microphoneHeaderItem = NSMenuItem.sectionHeader(title: localized("Microphone"))
    private let disconnectedItem = NSMenuItem()
    private let equalizerHeaderItem = NSMenuItem()
    private let equalizerBandsItem = NSMenuItem()
    private var sourceItems: [NSMenuItem] = []
    private var sourceUIDs: [String] = []

    public init(model: AppModel) {
        self.model = model
        menu = PanelMenu(title: "MicBoost")
        super.init()
        menu.autoenablesItems = false
        // No checkmark column: the selected microphone is marked by its row, so every row
        // starts at the menu's own left inset (docs/ui.md "Painel").
        menu.showsStateColumn = false
        menu.delegate = self
        buildMenu()
        wire()
        wireBareKeys()
        refresh()
    }

    // MARK: - Menu

    private func buildMenu() {
        let settings = NSMenuItem(
            title: localized("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(
            title: localized("Quit MicBoost"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        // Plain text, like the settings item of Apple's own menus: no icon before the title.
        if #available(macOS 27.0, *) {
            settings.preferredImageVisibility = .hidden
            quit.preferredImageVisibility = .hidden
        }
        // The bare "m" shortcut is native menu item matching, so it only fires while the panel
        // is open (docs/ui.md "Teclado e acessibilidade").
        let mute = NSMenuItem(title: localized("Mute"), action: #selector(mute), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = []
        mute.target = self
        mute.isHidden = true

        for (item, row) in [
            (headerItem, headerRow), (bannerItem, bannerRow), (gainItem, gainRow),
            (metersItem, metersRow), (routingItem, routingRow),
            (monitorItem, monitorRow), (monitorDetailItem, monitorDetailRow),
            (equalizerHeaderItem, equalizerHeaderRow), (equalizerBandsItem, equalizerBandsRow),
        ] {
            item.view = row
            item.isEnabled = true
        }
        disconnectedItem.isEnabled = false

        menu.addItem(headerItem)
        menu.addItem(gainItem)
        menu.addItem(metersItem)
        menu.addItem(monitorItem)
        menu.addItem(.separator())
        menu.addItem(routingItem)
        menu.addItem(microphoneHeaderItem)
        menu.addItem(.separator())
        menu.addItem(equalizerHeaderItem)
        menu.addItem(equalizerBandsItem)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(quit)
        menu.addItem(mute)
    }

    private func wire() {
        monitorRow.onToggle = { [weak self] enabled in
            self?.model.setMonitorEnabled(enabled)
            self?.refresh()
        }
        headerRow.onToggle = { [weak self] enabled in self?.model.processing(enabled) }
        gainRow.onMute = { [weak self] in self?.model.mute() }
        gainRow.onGain = { [weak self] db in self?.model.gain(db) }
        routingRow.onUseMicBoost = { [weak self] in self?.model.useBlackHole() }
        bannerRow.onAction = { [weak self] action in self?.run(action) }
        equalizerHeaderRow.onDisclose = { [weak self] in
            guard let self else { return }
            model.expanded.toggle()
            refresh()
        }
        equalizerHeaderRow.onEnable = { [weak self] enabled in
            guard let self else { return }
            model.controls.eq.enabled = enabled
            model.eq()
        }
        equalizerBandsRow.onGain = { [weak self] band, value in
            guard let self else { return }
            setGain(value, on: band)
            model.eq()
        }
        equalizerBandsRow.onFrequency = { [weak self] band, value in
            guard let self else { return }
            setFrequency(value, on: band)
            model.eq()
        }
        equalizerBandsRow.onWidth = { [weak self] value in
            guard let self else { return }
            model.controls.eq.mid.q = value
            model.eq()
        }
        equalizerBandsRow.onPreset = { [weak self] in
            self?.model.voicePreset()
            self?.refresh()
        }
        equalizerBandsRow.onReset = { [weak self] in
            self?.model.reset()
            self?.refresh()
        }
    }

    /// "m" toggles the mute while the panel is open (docs/ui.md "Teclado e acessibilidade").
    private func wireBareKeys() {
        (menu as? PanelMenu)?.onBareKey = { [weak self] event in
            guard let self, event.type == .keyDown else { return false }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
            guard event.charactersIgnoringModifiers?.lowercased() == "m" else { return false }
            // Typing in a field of a row keeps the key.
            let editing = menu.items.contains { $0.view?.window?.firstResponder is NSTextView }
            guard !editing else { return false }
            model.mute()
            refreshLive()
            return true
        }
    }

    private func setGain(_ value: Double, on band: EQBand) {
        switch band {
        case .low: model.controls.eq.low.gainDB = value
        case .mid: model.controls.eq.mid.gainDB = value
        case .high: model.controls.eq.high.gainDB = value
        }
    }

    private func setFrequency(_ value: Double, on band: EQBand) {
        switch band {
        case .low: model.controls.eq.low.frequency = value
        case .mid: model.controls.eq.mid.frequency = value
        case .high: model.controls.eq.high.frequency = value
        }
    }

    private func run(_ action: AppModel.StatusMessage.Action) {
        switch action {
        case .privacySettings:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .install:
            open("https://github.com/vittau/MicBoost#requirements")
        case .retry:
            model.retry()
        case .noAction:
            break
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Refresh

    /// Repaints the rows whose value changes with every meter sample.
    public func refreshLive() {
        gainRow.update(
            gainDB: model.controls.gainDB, muted: model.controls.muted, limiting: model.limitingUntil > Date())
        metersRow.update(inputDB: model.inputDB, outputDB: model.outputDB)
    }

    /// Rewrites every row from the model; runs on each state snapshot while the panel is open.
    public func refresh() {
        monitorRow.update(enabled: model.monitorEnabled, processing: model.controls.processingEnabled)
        monitorDetailRow.update(model.monitorDescription)
        setItem(
            monitorDetailItem,
            present: model.monitorEnabled && model.controls.processingEnabled && !model.monitorDescription.isEmpty,
            at: menu.index(of: monitorItem) + 1)
        headerRow.update(enabled: model.controls.processingEnabled)
        updateBanner()
        gainRow.update(
            gainDB: model.controls.gainDB, muted: model.controls.muted, limiting: model.limitingUntil > Date())
        metersRow.update(inputDB: model.inputDB, outputDB: model.outputDB)
        routingRow.update(model.routing)
        updateSources()
        equalizerHeaderRow.update(expanded: model.expanded, enabled: model.controls.eq.enabled)
        equalizerBandsRow.update(eq: model.controls.eq, sampleRate: model.status?.sampleRate ?? 48000)
        setBandsVisible(model.expanded)
    }

    /// The menu window only takes a new height when the item list changes: AppKit lays the
    /// open menu out from its items, and hiding an item leaves its space. The band rows are
    /// therefore inserted and removed while the panel is open (docs/ui.md "Painel").
    private func setBandsVisible(_ visible: Bool) {
        setItem(equalizerBandsItem, present: visible, at: menu.index(of: equalizerHeaderItem) + 1)
    }

    private func updateBanner() {
        guard let message = model.message else {
            setItem(bannerItem, present: false, at: 0)
            return
        }
        bannerRow.update(message, action: model.statusMessage?.action ?? .noAction)
        setItem(bannerItem, present: true, at: menu.index(of: headerItem) + 1)
    }

    /// The menu window only takes a new height when the item list changes: AppKit lays the
    /// open menu out from its items, and hiding an item leaves its space. Rows that appear and
    /// disappear are inserted and removed instead (docs/ui.md "Painel").
    private func setItem(_ item: NSMenuItem, present: Bool, at index: Int) {
        let isPresent = item.menu != nil
        if present && !isPresent {
            menu.insertItem(item, at: max(0, min(index, menu.numberOfItems)))
        } else if !present && isPresent {
            menu.removeItem(item)
        }
    }

    private func updateSources() {
        let sources = model.sources
        let uids = sources.map(\.uid)
        if uids != sourceUIDs {
            for item in sourceItems {
                menu.removeItem(item)
            }
            sourceItems = uids.map { uid in
                let row = PanelMicrophoneRow()
                let item = NSMenuItem()
                item.view = row
                item.target = self
                item.action = #selector(selectSource(_:))
                item.representedObject = uid
                item.isEnabled = true
                return item
            }
            var index = menu.index(of: microphoneHeaderItem) + 1
            for item in sourceItems {
                menu.insertItem(item, at: index)
                index += 1
            }
            sourceUIDs = uids
        }
        let selected = model.controls.selectedInputUID
        for (item, device) in zip(sourceItems, sources) {
            guard let row = item.view as? PanelMicrophoneRow else { continue }
            row.applyMetrics()
            row.update(
                name: device.name, symbol: Self.symbol(for: device),
                selected: device.uid == selected)
        }
        let showsDisconnected = selected.map { !uids.contains($0) } ?? false
        disconnectedItem.title = model.disconnectedSourceLabel
        setItem(
            disconnectedItem, present: showsDisconnected,
            at: menu.index(of: microphoneHeaderItem) + 1 + sourceItems.count)
    }

    /// One menu item per source, with the transport symbol, like the device lists of Control
    /// Center (docs/ui.md "Painel", item 5).
    static func symbol(for device: AudioDevice) -> String {
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeUSB: return "mic.fill"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        default: return "mic"
        }
    }

    /// Adopts the insets measured from the menu's own layout (docs/ui.md "Painel").
    private func applyMetrics() {
        for row in [
            headerRow, bannerRow, gainRow, metersRow, monitorRow, monitorDetailRow, routingRow, equalizerHeaderRow,
            equalizerBandsRow,
        ] {
            row.applyMetrics()
        }
        for item in sourceItems {
            (item.view as? PanelMicrophoneRow)?.applyMetrics()
        }
    }

    // MARK: - Actions

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
            let device = model.sources.first(where: { $0.uid == uid })
        else { return }
        model.select(device)
        refresh()
    }

    @objc private func openSettings() { model.onSettings() }

    @objc private func quit() { model.onQuit() }

    @objc private func mute() { model.mute() }

    public func close() { menu.cancelTracking() }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        refresh()
        onOpen()
        model.setPanelVisible(true)
        // The menu window is laid out after the delegate call: the insets of the native rows
        // are measured on the next main-actor turn, before the first click.
        Task { @MainActor [weak self] in
            guard let self else { return }
            MenuMetrics.measure(in: menu)
            applyMetrics()
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        model.setPanelVisible(false)
        onClose()
    }
}
