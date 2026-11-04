import AppKit
import SwiftUI
import Testing

@testable import MicBoostUI

@MainActor struct MenuSliderTests {
    private static func key(_ keyCode: UInt16, option: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode)!
    }

    @Test func actionWritesTheSliderValue() {
        var written: [Double] = []
        let slider = MenuSlider(
            value: 0, range: -12...24, step: 0.5, optionStep: 1, label: "Gain", valueText: "",
            onEdit: { written.append($0) })
        let coordinator = slider.makeCoordinator()
        let control = NSSlider(value: 0, minValue: -12, maxValue: 24, target: nil, action: nil)
        control.doubleValue = 14.5
        coordinator.valueChanged(control)
        #expect(written == [14.5])
    }

    @Test func externalValueMovesTheKnobOnlyWhenNotDragging() {
        let control = MenuSliderControl(frame: .zero)
        control.minValue = -12
        control.maxValue = 24
        control.reflect(6)
        #expect(control.doubleValue == 6)
        // The text field sets 0 dB in the middle of a drag: the knob follows the drag.
        control.isTrackingKnob = true
        control.reflect(0)
        #expect(control.doubleValue == 6)
        control.isTrackingKnob = false
        control.reflect(0)
        #expect(control.doubleValue == 0)
    }

    @Test func arrowKeysStepAndWriteThrough() {
        var written: [Double] = []
        let slider = MenuSlider(
            value: 0, range: -12...24, step: 0.5, optionStep: 1, label: "Gain", valueText: "",
            onEdit: { written.append($0) })
        let coordinator = slider.makeCoordinator()
        let control = MenuSliderControl(frame: .zero)
        control.target = coordinator
        control.action = #selector(MenuSlider.Coordinator.valueChanged(_:))
        control.minValue = -12
        control.maxValue = 24
        control.step = 0.5
        control.optionStep = 1
        control.keyDown(with: Self.key(124))
        #expect(control.doubleValue == 0.5)
        control.keyDown(with: Self.key(126, option: true))
        #expect(control.doubleValue == 1.5)
        control.keyDown(with: Self.key(123))
        #expect(control.doubleValue == 1)
        control.keyDown(with: Self.key(125))
        #expect(control.doubleValue == 0.5)
        #expect(written == [0.5, 1.5, 1, 0.5])
        // The range still bounds the value.
        control.doubleValue = 23.9
        control.keyDown(with: Self.key(124, option: true))
        #expect(control.doubleValue == 24)
    }

    @Test func panelUsesNativeSliders() {
        let model = AppModel()
        model.expanded = true
        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let sliders = Self.sliders(in: host)
        #expect(sliders.count == 5)
        let gain = sliders.first { $0.accessibilityLabel() == localized("Gain") }
        #expect(gain?.isContinuous == true)
        #expect(gain?.numberOfTickMarks == 0)
        #expect(gain?.accessibilityValue() as? String == AppModel.gainLabel(model.controls.gainDB))
    }

    private static func sliders(in view: NSView) -> [MenuSliderControl] {
        let own = (view as? MenuSliderControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { sliders(in: $0) }
    }
}
