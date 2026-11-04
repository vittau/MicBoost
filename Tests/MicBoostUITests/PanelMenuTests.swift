import AppKit
import CoreAudio
import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

/// The panel is a real `NSMenu`: its items, section headers, shortcuts and view rows are
/// inspected directly, without opening the menu or injecting events (docs/ui.md "Painel").
@MainActor struct PanelMenuTests {
    private static func device(_ uid: String, _ name: String, usb: Bool = false) -> AudioDevice {
        var device = AudioDevice(id: 1, uid: uid, name: name)
        device.inputChannels = 2
        device.transport = usb ? kAudioDeviceTransportTypeUSB : kAudioDeviceTransportTypeBuiltIn
        return device
    }

    private static func model() -> AppModel {
        let model = AppModel(statusGrace: .zero)
        var usb = device("usb", "USB Microphone", usb: true)
        usb.id = 2
        var internalMic = device("built-in", "MacBook Pro Microphone")
        internalMic.id = 3
        model.devices = [usb, internalMic]
        model.controls.selectedInputUID = "usb"
        model.apply(
            .init(
                state: .running, source: usb, defaultInput: .init(isBlackHole: true),
                defaultInputName: "MicBoost", sampleRate: 48000))
        return model
    }

    @Test func sectionOrderAndNativeItems() throws {
        let model = Self.model()
        let panel = PanelMenuController(model: model)
        let items = panel.menu.items
        #expect(items.filter(\.isSeparatorItem).count == 3)
        let header = try #require(items.first { $0.title == localized("Microphone") })
        #expect(header.isSectionHeader == true)
        let microphoneIndex = try #require(items.firstIndex(of: header))
        let sourceNames = items[(microphoneIndex + 1)...(microphoneIndex + 2)].compactMap {
            ($0.view as? PanelMicrophoneRow)?.accessibilityLabel()
        }
        #expect(sourceNames == ["USB Microphone", "MacBook Pro Microphone"])
        // Actions after the section: the equalizer rows, then the two text items in the footer.
        #expect(
            items.suffix(3).map(\.title) == [localized("Settings…"), localized("Quit MicBoost"), localized("Mute")])
        // Every action row is a real item; only controls live in view items.
        for item in items where item.view == nil && !item.isSeparatorItem {
            #expect(!item.title.isEmpty)
        }
    }

    @Test func selectedSourceIsMarkedAndOthersAreNot() {
        let model = Self.model()
        let panel = PanelMenuController(model: model)
        #expect(!panel.menu.showsStateColumn)
        let sources = panel.menu.items.filter { $0.representedObject != nil }
        #expect(sources.count == 2)
        let rows = sources.compactMap { $0.view as? PanelMicrophoneRow }
        #expect(rows.count == 2)
        #expect(sources[0].target === panel)
        #expect(sources[0].action != nil)
        #expect(sources[0].isEnabled)
        #expect(rows[0].accessibilityValue() as? String == localized("Selected"))
        #expect(rows[0].isAccessibilitySelected() == true)
        #expect(rows[1].accessibilityValue() as? String == "")
        #expect(rows[1].isAccessibilitySelected() == false)
        // Selecting another source moves the mark.
        model.controls.selectedInputUID = "built-in"
        panel.refresh()
        let updated = panel.menu.items.filter { $0.representedObject != nil }
            .compactMap { $0.view as? PanelMicrophoneRow }
        #expect(updated[0].isAccessibilitySelected() == false)
        #expect(updated[1].isAccessibilitySelected() == true)
    }

    @Test func clickingAMicrophoneRowSelectsIt() throws {
        let model = Self.model()
        model.controls.processingEnabled = false
        let panel = PanelMenuController(model: model)
        let item = try #require(panel.menu.items.first { $0.representedObject as? String == "built-in" })
        let row = try #require(item.view as? PanelMicrophoneRow)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: event)
        #expect(model.controls.selectedInputUID == "built-in")
    }

    @Test func noSourceSelectedAsksToChooseOne() {
        let model = AppModel(statusGrace: .zero)
        model.controls.processingEnabled = true
        model.error = .noSourceSelected
        #expect(model.statusMessage == .noSourceSelected)
        #expect(model.message == localized("Choose a microphone in the list."))
    }

    @Test func transportSymbols() {
        #expect(PanelMenuController.symbol(for: Self.device("usb", "USB", usb: true)) == "mic.fill")
        var bluetooth = Self.device("bt", "Headset")
        bluetooth.transport = kAudioDeviceTransportTypeBluetooth
        #expect(PanelMenuController.symbol(for: bluetooth) == "headphones")
        #expect(PanelMenuController.symbol(for: Self.device("built-in", "Internal")) == "mic")
    }

    @Test func absentSourceKeepsTheDisconnectedRow() {
        let model = Self.model()
        model.controls.knownSourceNames = ["gone": "fifine Microphone"]
        model.controls.selectedInputUID = "gone"
        model.devices = []
        let panel = PanelMenuController(model: model)
        let rows = panel.menu.items.filter { $0.title.contains(localized("(disconnected)")) }
        #expect(rows.count == 1)
        #expect(rows.first?.title == "fifine Microphone (disconnected)")
        #expect(rows.first?.isEnabled == false)
        #expect(!rows[0].title.contains("gone"))
        // With every source present, the row leaves the menu.
        model.devices = [Self.device("usb", "USB Microphone"), Self.device("built-in", "MacBook Pro Microphone")]
        model.controls.selectedInputUID = "usb"
        panel.refresh()
        #expect(!panel.menu.items.contains { $0.title.contains(localized("(disconnected)")) })
    }

    @Test func shortcutsAreNativeMenuEquivalents() {
        let panel = PanelMenuController(model: Self.model())
        let settings = panel.menu.items.first { $0.keyEquivalent == "," }
        let quit = panel.menu.items.first { $0.keyEquivalent == "q" }
        let mute = panel.menu.items.first { $0.keyEquivalent == "m" }
        #expect(settings?.keyEquivalentModifierMask == .command)
        #expect(quit?.keyEquivalentModifierMask == .command)
        #expect(mute?.keyEquivalentModifierMask == [])
        #expect(mute?.isHidden == true)
        #expect(settings?.action != nil && quit?.action != nil && mute?.action != nil)
    }

    @Test func equalizerRowsFollowTheExpansion() {
        let model = Self.model()
        model.expanded = false
        let panel = PanelMenuController(model: model)
        #expect(!panel.menu.items.contains { $0.view is PanelEQBandsRow })
        model.expanded = true
        panel.refresh()
        #expect(panel.menu.items.contains { $0.view is PanelEQBandsRow })
        #expect(panel.menu.items.contains { $0.view is PanelEQHeaderRow })
    }

    @Test func bannerAppearsOnlyWithAMessage() {
        let model = Self.model()
        let panel = PanelMenuController(model: model)
        #expect(!panel.menu.items.contains { $0.view is PanelBannerRow })
        model.apply(.init(state: .error(.blackHoleMissing)))
        panel.refresh()
        #expect(panel.menu.items.contains { $0.view is PanelBannerRow })
        model.apply(.init(state: .running, defaultInput: .init(isBlackHole: true)))
        panel.refresh()
        #expect(!panel.menu.items.contains { $0.view is PanelBannerRow })
    }

    @Test func customRowsUseAppKitControls() {
        let model = Self.model()
        model.expanded = true
        let panel = PanelMenuController(model: model)
        let rows = panel.menu.items.compactMap(\.view)
        let sliders = rows.flatMap(Self.sliders)
        // Gain, three band gains and the width of the mid band.
        #expect(sliders.count == 5)
        let gain = sliders.first { $0.accessibilityLabel() == localized("Gain") }
        #expect(gain?.isContinuous == true)
        #expect(gain?.numberOfTickMarks == 0)
        #expect(gain?.accessibilityValue() as? String == AppModel.gainLabel(model.controls.gainDB))
        // Every switch of the panel is a native NSSwitch.
        let switches = rows.flatMap(Self.switches)
        #expect(switches.count == 2)
        #expect(switches.allSatisfy { $0 is NSSwitch })
        // The meters are the native level indicator.
        let meters = rows.flatMap(Self.meters)
        #expect(meters.count == 2)
        #expect(meters.allSatisfy { $0.levelIndicatorStyle == .continuousCapacity })
        #expect(meters.allSatisfy { $0.warningValue > $0.maxValue && $0.criticalValue > $0.maxValue })
        #expect(meters.first?.accessibilityRole() == .levelIndicator)
    }

    @Test func limiterBadgeKeepsTheRowSize() {
        let quiet = Self.model()
        quiet.limitingUntil = .distantPast
        let quietPanel = PanelMenuController(model: quiet)
        let limiting = Self.model()
        limiting.limitingUntil = .distantFuture
        let limitingPanel = PanelMenuController(model: limiting)
        let quietRow = quietPanel.menu.items.first { $0.view is PanelGainRow }?.view
        let limitingRow = limitingPanel.menu.items.first { $0.view is PanelGainRow }?.view
        #expect(quietRow?.frame.size == limitingRow?.frame.size)
        #expect((quietRow?.frame.width ?? 0) > 0)
    }

    @Test func gainValueIsReadOnlyText() {
        let model = Self.model()
        let panel = PanelMenuController(model: model)
        let row = panel.menu.items.first { $0.view is PanelGainRow }?.view
        let label = row.flatMap { Self.textFields(in: $0) }?
            .first { $0.accessibilityLabel() == localized("Gain") }
        #expect(label?.stringValue == AppModel.gainLabel(model.controls.gainDB))
        #expect(label?.isEditable == false)
        #expect(label?.isSelectable == false)
    }

    @Test func metersIgnoreTheMouseAndTheFocus() {
        let panel = PanelMenuController(model: Self.model())
        let meters = panel.menu.items.compactMap(\.view).flatMap(Self.meters)
        #expect(meters.count == 2)
        for meter in meters {
            // The meter is a display: a click belongs to the row and never reaches it.
            #expect(meter.hitTest(NSPoint(x: 1, y: 1)) == nil)
            #expect(!meter.acceptsFirstResponder)
            #expect(meter.refusesFirstResponder)
        }
    }

    private static func sliders(in view: NSView) -> [MenuSliderControl] {
        let own = (view as? MenuSliderControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { sliders(in: $0) }
    }

    private static func switches(in view: NSView) -> [NSSwitch] {
        let own = (view as? NSSwitch).map { [$0] } ?? []
        return own + view.subviews.flatMap { switches(in: $0) }
    }

    private static func meters(in view: NSView) -> [LevelMeterIndicator] {
        let own = (view as? LevelMeterIndicator).map { [$0] } ?? []
        return own + view.subviews.flatMap { meters(in: $0) }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }
}

/// Commit rule of the numeric menu fields (docs/ui.md "Teclado e acessibilidade").
@MainActor struct MenuNumberFieldTests {
    @Test func parseAcceptsCommaAndDotDecimals() {
        #expect(MenuNumberField.parse("1,5", locale: Locale(identifier: "pt_BR")) == 1.5)
        #expect(MenuNumberField.parse("1.5", locale: Locale(identifier: "pt_BR")) == 1.5)
        #expect(MenuNumberField.parse("1.5", locale: Locale(identifier: "en_US")) == 1.5)
        #expect(MenuNumberField.parse("1,5", locale: Locale(identifier: "en_US")) == 1.5)
        #expect(MenuNumberField.parse("-12,25", locale: Locale(identifier: "pt_BR")) == -12.25)
        #expect(MenuNumberField.parse(" 1200 ", locale: Locale(identifier: "pt_BR")) == 1200)
    }

    @Test func parseRejectsEmptyAndInvalidText() {
        #expect(MenuNumberField.parse("", locale: .current) == nil)
        #expect(MenuNumberField.parse("   ", locale: .current) == nil)
        #expect(MenuNumberField.parse("-", locale: .current) == nil)
        // A trailing separator is a partial decimal, not a rejected number.
        #expect(MenuNumberField.parse("1,", locale: Locale(identifier: "pt_BR")) == 1)
        #expect(MenuNumberField.parse("abc", locale: .current) == nil)
        #expect(MenuNumberField.parse("nan", locale: .current) == nil)
        #expect(MenuNumberField.parse("inf", locale: .current) == nil)
    }

    @Test func parseKeepsOutOfRangeValuesForTheModelToClamp() {
        #expect(MenuNumberField.parse("9999", locale: .current) == 9999)
        #expect(MenuNumberField.parse("-40", locale: .current) == -40)
        // The model clamps the gain to its documented range.
        let model = AppModel(statusGrace: .zero)
        model.gain(100)
        #expect(model.controls.gainDB == Settings.gainRange.upperBound)
        model.gain(-100)
        #expect(model.controls.gainDB == Settings.gainRange.lowerBound)
    }

    @Test func editingTextIsNeverReformatted() {
        let field = MenuNumberField(width: 80)
        field.show(6, fractionDigits: 1)
        let shown = field.stringValue
        field.isEditingText = true
        field.stringValue = ""
        // A model update in the middle of the edit keeps what the user typed.
        field.show(12, fractionDigits: 1)
        #expect(field.stringValue == "")
        // Empty input on commit changes nothing and shows the current value again.
        var committed: [Double] = []
        field.onCommit = { committed.append($0) }
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(committed.isEmpty)
        #expect(field.stringValue == MenuNumberField.format(12, fractionDigits: 1, locale: .current))
        #expect(!shown.isEmpty)
        // Invalid input behaves the same way.
        field.isEditingText = true
        field.stringValue = "-"
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(committed.isEmpty)
        // Valid input commits the typed value.
        field.isEditingText = true
        field.stringValue = "3,5"
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(committed == [3.5])
    }
}
