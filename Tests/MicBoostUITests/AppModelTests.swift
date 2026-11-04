import AppKit
import Foundation
import MicBoostCore
import SwiftUI
import Testing

@testable import MicBoostUI

@MainActor struct AppModelTests {
    @Test func gainFormatting() {
        #expect(AppModel.gainLabel(12, locale: .init(identifier: "pt_BR")) == "398% (+12,0dB)")
        #expect(AppModel.gainLabel(2, locale: .init(identifier: "pt_BR")) == "126% (+2,0dB)")
        #expect(AppModel.gainStep(option: false) == 0.5)
        #expect(AppModel.gainStep(option: true) == 1)
    }
    @Test func states() {
        let model = AppModel()
        model.controls.processingEnabled = false
        #expect(model.icon == "mic")
        model.controls.processingEnabled = true
        model.controls.muted = true
        #expect(model.icon == "mic.slash.fill")
        model.error = .blackHoleMissing
        #expect(model.icon == "exclamationmark.triangle.fill")
        #expect(model.message != nil)
        model.controls.processingEnabled = false
        #expect(model.icon == "mic")
    }
}

@MainActor @Test func processingSwitchPersistsAndStops() async throws {
    let store = SettingsStore(storage: UserDefaultsStorage(defaults: UserDefaults(suiteName: "MicBoostUITests")!))
    let model = AppModel(store: store)
    model.processing(false)
    await model.finishCommands()
    #expect(!(await store.current).processingEnabled)
    #expect((await model.engine.status()).state == .stopped)
    model.processing(true)
    await model.finishCommands()
    #expect((await store.current).processingEnabled)
    #expect(model.error == .noSourceSelected)
    try await model.shutdown()
}

@MainActor @Test func statusMessageMapping() {
    let model = AppModel()
    model.controls.processingEnabled = true
    var source = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    source.inputChannels = 1

    model.apply(.init(state: .error(.microphonePermissionDenied)))
    #expect(model.statusMessage == .permissionDenied)
    #expect(model.statusMessage?.action == .privacySettings)
    #expect(model.message == localized("Microphone access denied."))

    model.apply(.init(state: .error(.blackHoleMissing)))
    #expect(model.statusMessage == .blackHoleMissing)
    #expect(model.statusMessage?.action == .install)
    #expect(model.message == localized("BlackHole 2ch not found."))

    model.apply(.init(state: .error(.sourceUnavailable("usb")), source: source))
    #expect(model.statusMessage == .sourceLost("USB Microphone"))
    #expect(model.statusMessage?.action == .noAction)
    #expect(model.message == "USB Microphone disconnected. Audio resumes when it is reconnected.")

    model.apply(.init(state: .recovering(.sourceLost), source: source))
    #expect(model.statusMessage == .sourceLost("USB Microphone"))
    #expect(model.message != nil)

    model.apply(.init(state: .error(.formatUnsupported)))
    #expect(model.statusMessage == .formatUnsupported)
    #expect(model.statusMessage?.action == .noAction)

    model.apply(.init(state: .error(.halFailure(-1, "Start"))))
    #expect(model.statusMessage == .systemFailure)
    #expect(model.statusMessage?.action == .retry)
    #expect(model.message == localized("System audio failed."))

    model.apply(.init(state: .recovering(.wakeFailed)))
    #expect(model.statusMessage == .systemFailure)
    #expect(model.statusMessage?.action == .retry)

    for state: EngineState in [.recovering(.formatChanged), .recovering(.serviceRestarted), .recovering(.sleep)] {
        model.apply(.init(state: state))
        #expect(model.statusMessage == nil)
        #expect(model.message == nil)
    }

    model.apply(.init(state: .running, source: source, defaultInput: .init(isBlackHole: true)))
    #expect(model.statusMessage == nil)
    #expect(model.error == nil)
}

@MainActor @Test func blackHoleReturnClearsTheMessageByItself() {
    let model = AppModel()
    model.controls.processingEnabled = true
    model.apply(.init(state: .error(.blackHoleMissing)))
    #expect(model.message != nil)
    // Reappearing BlackHole: the engine rebuilds and reports running.
    model.apply(.init(state: .recovering(.formatChanged)))
    model.apply(.init(state: .running, defaultInput: .init(isBlackHole: true)))
    #expect(model.error == nil)
    #expect(model.message == nil)
    #expect(model.icon == "mic.fill")
}

@MainActor @Test func permissionGrantedOnActivationRestartsProcessing() async {
    let model = AppModel()
    model.controls.processingEnabled = true
    model.controls.selectedInputUID = nil
    model.authorization = { .denied }
    model.error = .microphonePermissionDenied
    model.applicationDidBecomeActive()
    #expect(model.statusMessage == .permissionDenied)
    model.authorization = { .authorized }
    model.applicationDidBecomeActive()
    await model.finishCommands()
    // No microphone is selected, so the retried start stops before touching the HAL.
    #expect(model.error == .noSourceSelected)
    #expect(model.statusMessage != .permissionDenied)
}

@MainActor @Test func permissionGrantedOnActivationClearsBannerWhenProcessingIsOff() async {
    let model = AppModel()
    model.controls.processingEnabled = false
    model.authorization = { .denied }
    model.error = .microphonePermissionDenied
    model.applicationDidBecomeActive()
    #expect(model.statusMessage == nil)
}

@MainActor @Test func limiterBadgeKeepsPanelSize() {
    let quiet = AppModel()
    quiet.limitingUntil = .distantPast
    let limiting = AppModel()
    limiting.limitingUntil = .distantFuture
    let quietSize = NSHostingView(rootView: PanelView(model: quiet)).fittingSize
    let limitingSize = NSHostingView(rootView: PanelView(model: limiting)).fittingSize
    #expect(quietSize.width == 320 && quietSize.height > 0)
    #expect(limitingSize == quietSize)
}

@MainActor @Test func meterScaleReachesItsEndpoints() {
    #expect(AppModel.meterFraction(-60) == 0)
    #expect(abs(AppModel.meterFraction(-30) - sqrt(0.001)) < 1e-12)
    #expect(AppModel.meterFraction(0) == 1)
    #expect(AppModel.meterFraction(6) == 1)
    #expect(AppModel.meterFraction(-90) == 0)
    #expect(abs(AppModel.meterFraction(-1) - pow(10, -1.0 / 20)) < 1e-12)
    #expect(AppModel.meterFraction(.nan) == 0)
}

@MainActor @Test func meterLengthTracksAmplitudeGain() {
    let doublingDB = 20 * log10(2.0)
    for inputAmplitude in [0.01, 0.1, 0.4] {
        let inputDB = 20 * log10(inputAmplitude)
        let inputLength = AppModel.meterFraction(inputDB)
        let outputLength = AppModel.meterFraction(inputDB + doublingDB)
        #expect(abs(inputLength - inputAmplitude) < 1e-12)
        #expect(abs(outputLength - 2 * inputLength) < 1e-12)
    }
}
