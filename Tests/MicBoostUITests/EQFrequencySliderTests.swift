import AppKit
import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

/// Frequency grid and logarithmic scale of the equalizer sliders, and the slider wiring of the
/// menu rows (docs/dsp.md "Equalizador", docs/ui.md "Painel", item 10).
@MainActor struct EQFrequencySliderTests {
    private static func key(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode)!
    }

    private static func sliders(in view: NSView) -> [MenuSliderControl] {
        let own = (view as? MenuSliderControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { sliders(in: $0) }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }

    /// A panel with the EQ expanded and the default (voice preset) settings.
    private static func panel() throws -> (AppModel, PanelMenuController, PanelEQBandsRow) {
        let model = AppModel(statusGrace: .zero)
        model.expanded = true
        let panel = PanelMenuController(model: model)
        let bands = try #require(
            panel.menu.items.compactMap(\.view).first { $0 is PanelEQBandsRow } as? PanelEQBandsRow)
        return (model, panel, bands)
    }

    private static func frequencySlider(_ band: String, in bands: PanelEQBandsRow) throws -> MenuSliderControl {
        try #require(sliders(in: bands).first { $0.accessibilityLabel() == "\(band), Hz" })
    }

    @Test func gridSnapsAtTheTierBoundaries() {
        // The step changes with the tier, and a value near a boundary rounds to the grid of
        // its own tier, so the grid stays continuous (docs/dsp.md "Equalizador").
        #expect(EQFrequencyScale.quantized(195) == 200)
        #expect(EQFrequencyScale.quantized(199) == 200)
        #expect(EQFrequencyScale.quantized(200) == 200)
        #expect(EQFrequencyScale.quantized(950) == 1000)
        #expect(EQFrequencyScale.quantized(999) == 1000)
        #expect(EQFrequencyScale.quantized(1000) == 1000)
        #expect(EQFrequencyScale.quantized(1240) == 1000)
        #expect(EQFrequencyScale.quantized(1250) == 1500)
        #expect(EQFrequencyScale.quantized(9750) == 10000)
        #expect(EQFrequencyScale.quantized(9999) == 10000)
        #expect(EQFrequencyScale.quantized(10000) == 10000)
        #expect(EQFrequencyScale.quantized(10400) == 10000)
        #expect(EQFrequencyScale.quantized(14000) == 14000)
        // Just below a boundary: the smaller step of the tier still rounds up to the first
        // value of the next tier.
        #expect(EQFrequencyScale.quantized(194) == 190)
        #expect(EQFrequencyScale.quantized(949) == 900)
        #expect(EQFrequencyScale.quantized(9749) == 9500)
        #expect(EQFrequencyScale.quantized(10499) == 10000)
        #expect(EQFrequencyScale.quantized(10500) == 11000)
    }

    @Test func bandLimitsAndDefaultsAreOnTheGrid() {
        let values = [
            EQSettings.lowFrequencyRange.lowerBound, EQSettings.lowFrequencyRange.upperBound,
            EQSettings.midFrequencyRange.lowerBound, EQSettings.midFrequencyRange.upperBound,
            EQSettings.highFrequencyRange.lowerBound, EQSettings.highFrequencyRange.upperBound,
            70, 3000, 8000,
        ]
        for value in values {
            #expect(EQFrequencyScale.quantized(value) == value)
        }
    }

    @Test func arrowStepsFollowTheGridAcrossTiers() {
        let low = EQSettings.lowFrequencyRange
        #expect(EQFrequencyScale.stepped(from: 70, by: 1, in: low) == 80)
        #expect(EQFrequencyScale.stepped(from: 70, by: -1, in: low) == 60)
        #expect(EQFrequencyScale.stepped(from: 200, by: 1, in: 40...14000) == 300)
        #expect(EQFrequencyScale.stepped(from: 200, by: -1, in: 40...14000) == 190)
        let mid = EQSettings.midFrequencyRange
        #expect(EQFrequencyScale.stepped(from: 3000, by: 1, in: mid) == 3500)
        #expect(EQFrequencyScale.stepped(from: 3000, by: -1, in: mid) == 2500)
        #expect(EQFrequencyScale.stepped(from: 1000, by: 1, in: mid) == 1500)
        #expect(EQFrequencyScale.stepped(from: 1000, by: -1, in: mid) == 900)
        let high = 2000.0...14000.0
        #expect(EQFrequencyScale.stepped(from: 10000, by: 1, in: high) == 11000)
        #expect(EQFrequencyScale.stepped(from: 10000, by: -1, in: high) == 9500)
        // At the band limits the value stays put instead of leaving the range.
        #expect(EQFrequencyScale.stepped(from: 40, by: -1, in: low) == 40)
        #expect(EQFrequencyScale.stepped(from: 500, by: 1, in: low) == 500)
        #expect(EQFrequencyScale.stepped(from: 14000, by: 1, in: high) == 14000)
    }

    @Test func logMappingRoundTrips() {
        for range in [EQSettings.lowFrequencyRange, EQSettings.midFrequencyRange, EQSettings.highFrequencyRange] {
            #expect(EQFrequencyScale.position(of: range.lowerBound, in: range) == 0)
            #expect(EQFrequencyScale.position(of: range.upperBound, in: range) == 1)
            let middle = (range.lowerBound * range.upperBound).squareRoot()
            #expect(abs(EQFrequencyScale.frequency(at: 0.5, in: range) - middle) < 1e-9)
            for hz in [range.lowerBound, range.upperBound, range.lowerBound * 3.7] {
                let position = EQFrequencyScale.position(of: hz, in: range)
                #expect(abs(EQFrequencyScale.frequency(at: position, in: range) - hz) < 0.001)
                #expect(
                    abs(
                        EQFrequencyScale.position(of: EQFrequencyScale.frequency(at: position, in: range), in: range)
                            - position) < 1e-12)
            }
            // Values outside the band clamp to its ends.
            #expect(EQFrequencyScale.position(of: range.lowerBound - 100, in: range) == 0)
            #expect(EQFrequencyScale.position(of: range.upperBound + 100, in: range) == 1)
        }
    }

    @Test func draggingTheFrequencySliderQuantizesAndUpdatesTheBand() throws {
        let (model, panel, bands) = try Self.panel()
        let slider = try Self.frequencySlider(localized("Mid"), in: bands)
        // The row keeps the knob where the drag put it and writes the quantized value.
        slider.isTrackingKnob = true
        slider.doubleValue = 1
        slider.sendAction(slider.action, to: slider.target)
        #expect(model.controls.eq.mid.frequency == EQSettings.midFrequencyRange.upperBound)
        let position = 0.5
        slider.doubleValue = position
        slider.sendAction(slider.action, to: slider.target)
        let raw = EQFrequencyScale.frequency(at: position, in: EQSettings.midFrequencyRange)
        let expected = EQFrequencyScale.quantized(raw)
        #expect(model.controls.eq.mid.frequency == expected)
        #expect(expected == 1000)
        #expect(Self.textFields(in: bands).contains { $0.stringValue == "1000 Hz" })
        #expect(slider.accessibilityValue() as? String == "1000 Hz")
        // A model value that arrives while the knob is held does not move it.
        slider.doubleValue = 0.75
        panel.refresh()
        #expect(slider.doubleValue == 0.75)
    }

    @Test func arrowKeysMoveToTheNextGridValueThroughTheModel() throws {
        _ = NSApplication.shared
        let (model, _, bands) = try Self.panel()
        let slider = try Self.frequencySlider(localized("Mid"), in: bands)
        slider.keyDown(with: Self.key(123))  // left
        #expect(model.controls.eq.mid.frequency == 2500)
        slider.keyDown(with: Self.key(124))  // right
        #expect(model.controls.eq.mid.frequency == 3000)
        slider.keyDown(with: Self.key(126))  // up
        #expect(model.controls.eq.mid.frequency == 3500)
        slider.keyDown(with: Self.key(125))  // down
        #expect(model.controls.eq.mid.frequency == 3000)
        #expect(slider.accessibilityValue() as? String == "3000 Hz")
    }

    @Test func persistedOffGridValueIsShownUntilTheSliderMoves() throws {
        let (model, panel, bands) = try Self.panel()
        model.controls.eq.mid.frequency = 1234
        panel.refresh()
        let slider = try Self.frequencySlider(localized("Mid"), in: bands)
        #expect(Self.textFields(in: bands).contains { $0.stringValue == "1234 Hz" })
        #expect(abs(slider.doubleValue - EQFrequencyScale.position(of: 1234, in: EQSettings.midFrequencyRange)) < 1e-9)
        #expect(model.controls.eq.mid.frequency == 1234)
        // The first drag quantizes it.
        slider.isTrackingKnob = true
        slider.doubleValue = EQFrequencyScale.position(of: 1234, in: EQSettings.midFrequencyRange)
        slider.sendAction(slider.action, to: slider.target)
        #expect(model.controls.eq.mid.frequency == 1000)
    }

    @Test func sliderMaximumFollowsTheSampleRate() throws {
        let (model, panel, bands) = try Self.panel()
        model.apply(.init(state: .running, sampleRate: 16000))
        panel.refresh()
        let slider = try Self.frequencySlider(localized("Treble"), in: bands)
        // The high shelf is capped at 45% of the sample rate; the grid then snaps it.
        slider.isTrackingKnob = true
        slider.doubleValue = 1
        slider.sendAction(slider.action, to: slider.target)
        #expect(model.controls.eq.high.frequency == 7000)
    }

    @Test func frequencyValueIsReadOnlyText() throws {
        let (_, _, bands) = try Self.panel()
        let values = Self.textFields(in: bands).filter { $0.stringValue.hasSuffix(" Hz") }
        #expect(values.map(\.stringValue) == ["70 Hz", "3000 Hz", "8000 Hz"])
        #expect(values.allSatisfy { !$0.isEditable && !$0.isSelectable })
        #expect(Self.sliders(in: bands).allSatisfy { $0.numberOfTickMarks == 0 })
    }
}
