import AppKit
import Testing

@testable import MicBoostUI

@MainActor struct MenuSliderTests {
    private static func key(_ keyCode: UInt16, option: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode)!
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
        // The control sends its action through the application object.
        _ = NSApplication.shared
        var written: [Double] = []
        let control = MenuSliderControl(frame: .zero)
        let writer = SliderWriter { written.append($0) }
        control.target = writer
        control.action = #selector(SliderWriter.fire(_:))
        control.minValue = -12
        control.maxValue = 24
        control.step = 0.5
        control.optionStep = 1
        // A control's target is weak, so the writer must outlive the events.
        withExtendedLifetime(writer) {
            control.keyDown(with: Self.key(124))
            #expect(control.doubleValue == 0.5)
            control.keyDown(with: Self.key(126, option: true))
            #expect(control.doubleValue == 1.5)
            control.keyDown(with: Self.key(123))
            #expect(control.doubleValue == 1)
            control.keyDown(with: Self.key(125))
            #expect(control.doubleValue == 0.5)
            // The range still bounds the value.
            control.doubleValue = 23.9
            control.keyDown(with: Self.key(124, option: true))
            #expect(control.doubleValue == 24)
        }
        #expect(written == [0.5, 1.5, 1, 0.5, 24])
    }
}

/// Receives the slider action, standing in for the panel row.
@MainActor final class SliderWriter: NSObject {
    private let handler: (Double) -> Void
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSSlider) { handler(sender.doubleValue) }
}
