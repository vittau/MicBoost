import Foundation
import MicBoostCore
import Testing

@testable import MicBoostUI

@MainActor struct AppModelTests {
    @Test func gainFormatting() {
        #expect(AppModel.gainLabel(12, locale: .init(identifier: "pt_BR")) == "+12,0 dB · 398%")
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
