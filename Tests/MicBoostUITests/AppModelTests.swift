import AppKit
import CoreAudio
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
        let model = AppModel(statusGrace: .zero)
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
    let model = AppModel(statusGrace: .zero)
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
    let model = AppModel(statusGrace: .zero)
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

@MainActor @Test func bufferPickerAlwaysHasASelection() {
    let normal = AppModel.bufferPicker(sourceBufferRange: .init(8, 2250), current: 256)
    #expect(normal.values == Settings.allowedBufferFrames)
    #expect(normal.selection == 256)
    #expect(normal.values.contains(normal.selection))
    // A source that reports no buffer range keeps every allowed size.
    let unknown = AppModel.bufferPicker(sourceBufferRange: .init(0, 0), current: 256)
    #expect(unknown.values == Settings.allowedBufferFrames)
    #expect(unknown.selection == 256)
    #expect(unknown.values.contains(unknown.selection))
    let missing = AppModel.bufferPicker(sourceBufferRange: nil, current: 1024)
    #expect(missing.values == Settings.allowedBufferFrames)
    #expect(missing.selection == 1024)
    // A persisted size the source does not support selects the closest offered size.
    let narrow = AppModel.bufferPicker(sourceBufferRange: .init(5, 260), current: 512)
    #expect(narrow.values == [64, 128, 256])
    #expect(narrow.selection == 256)
    #expect(narrow.values.contains(narrow.selection))
    // A range between two allowed sizes still offers values instead of an empty list.
    let gap = AppModel.bufferPicker(sourceBufferRange: .init(300, 400), current: 256)
    #expect(gap.values == Settings.allowedBufferFrames)
    #expect(gap.values.contains(gap.selection))
}

@MainActor @Test func channelPickerAlwaysHasASelection() {
    let stereo = AppModel.channelPicker(selection: .mono(channel: 1), channelCount: 2)
    #expect(stereo.values == [1, 2, -1, -2])
    #expect(stereo.selection == 1)
    let clamped = AppModel.channelPicker(selection: .mono(channel: 3), channelCount: 2)
    #expect(clamped.selection == 2)
    let eight = AppModel.channelPicker(selection: .mono(channel: 4), channelCount: 8)
    #expect(eight.selection == 4)
    let stereoEight = AppModel.channelPicker(selection: .stereo(firstChannel: 1), channelCount: 8)
    #expect(stereoEight.selection == -2)
    let single = AppModel.channelPicker(selection: .stereo(firstChannel: 1), channelCount: 1)
    #expect(single.values == [1, -1])
    #expect(single.selection == 1)
    let mix = AppModel.channelPicker(selection: .monoMix, channelCount: 1)
    #expect(mix.selection == -1)
    for picker in [stereo, clamped, eight, stereoEight, single, mix] {
        #expect(picker.values.contains(picker.selection))
    }
}

@MainActor @Test func disconnectedSourceUsesItsLastKnownName() {
    let model = AppModel()
    model.controls.selectedInputUID = "usb"
    // A source never seen has no name, so the row falls back to the generic label.
    #expect(model.selectedSourceName == nil)
    #expect(model.disconnectedSourceLabel == localized("Disconnected microphone"))
    model.controls.knownSourceNames = ["usb": "fifine Microphone"]
    #expect(model.selectedSourceName == "fifine Microphone")
    #expect(
        model.disconnectedSourceLabel
            == String.localizedStringWithFormat(localized("%@ (disconnected)"), "fifine Microphone"))
    // The raw UID never reaches the row.
    #expect(!model.disconnectedSourceLabel.contains("usb"))
    // A source reported by the engine outranks the persisted name; another device does not.
    var present = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    present.inputChannels = 1
    model.apply(.init(state: .running, source: present))
    #expect(model.selectedSourceName == "USB Microphone")
    var other = AudioDevice(id: 2, uid: "other", name: "Other Microphone")
    other.inputChannels = 1
    model.apply(.init(state: .running, source: other))
    #expect(model.selectedSourceName == "fifine Microphone")
}

@MainActor @Test func sourceLostBannerUsesTheLastKnownNameAfterARelaunch() {
    let model = AppModel(statusGrace: .zero)
    model.controls.processingEnabled = true
    model.controls.selectedInputUID = "usb"
    model.controls.knownSourceNames = ["usb": "fifine Microphone"]
    // The engine starts with nothing to report: the name comes from the persisted map.
    model.apply(.init(state: .recovering(.sourceLost)))
    #expect(model.statusMessage == .sourceLost("fifine Microphone"))
    #expect(
        model.message
            == String.localizedStringWithFormat(
                localized("%@ disconnected. Audio resumes when it is reconnected."), "fifine Microphone"))
    model.apply(.init(state: .error(.sourceUnavailable("usb"))))
    #expect(model.statusMessage == .sourceLost("fifine Microphone"))
}

@MainActor @Test func knownSourceNamesAreRemembered() {
    let model = AppModel()
    var source = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    source.inputChannels = 1
    model.rememberSourceNames([source, AudioDevice(id: 9, uid: "empty", name: "")])
    #expect(model.controls.knownSourceNames == ["usb": "USB Microphone"])
    var renamed = source
    renamed.name = "Renamed Microphone"
    model.rememberSourceNames([renamed])
    #expect(model.controls.knownSourceNames == ["usb": "Renamed Microphone"])
}

@MainActor @Test func deviceAbsenceBannersWaitForTheGrace() async throws {
    let model = AppModel(statusGrace: .milliseconds(100))
    model.controls.processingEnabled = true
    model.controls.selectedInputUID = "usb"
    model.controls.knownSourceNames = ["usb": "fifine Microphone"]
    // A flap shorter than the grace (a coreaudiod restart) never shows a banner: both states
    // arrive back to back, and the cancelling state below arrives before the grace elapses.
    model.apply(.init(state: .recovering(.serviceRestarted)))
    model.apply(.init(state: .error(.blackHoleMissing)))
    #expect(model.message == nil)
    model.apply(.init(state: .running, defaultInput: .init(isBlackHole: true)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.message == nil)
    // A real absence shows the banner after the grace.
    model.apply(.init(state: .error(.blackHoleMissing)))
    #expect(model.message == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.statusMessage == .blackHoleMissing)
    // The disconnected source follows the same rule and keeps the last known name.
    model.apply(.init(state: .recovering(.sourceLost)))
    #expect(model.message == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.statusMessage == .sourceLost("fifine Microphone"))
}

@MainActor @Test func immediateBannersDoNotWaitForTheGrace() {
    let model = AppModel()
    model.controls.processingEnabled = true
    model.apply(.init(state: .error(.microphonePermissionDenied)))
    #expect(model.statusMessage == .permissionDenied)
    model.apply(.init(state: .error(.halFailure(-1, "Start"))))
    #expect(model.statusMessage == .systemFailure)
}

@MainActor @Test func routingRowHoldsThroughAServiceRestart() async throws {
    let model = AppModel(statusGrace: .milliseconds(100))
    var source = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    source.inputChannels = 1
    var blackHole = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    blackHole.inputChannels = 2
    blackHole.outputChannels = 2
    model.devices = [source, blackHole]
    let running = EngineStatus(
        state: .running, source: source, blackHole: blackHole, defaultInput: .init(isBlackHole: true),
        defaultInputName: "MicBoost")
    model.apply(running)
    #expect(
        model.routing == AppModel.Routing(isBlackHole: true, running: true, canUseMicBoost: true))
    // The service restarts and the default input cannot be resolved for a moment: the row
    // keeps the last known state instead of flashing "Unknown" with a disabled button.
    model.apply(.init(state: .recovering(.serviceRestarted), defaultInput: .unresolved))
    #expect(model.routing.isBlackHole)
    #expect(model.routing.running)
    model.apply(running)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.routing.isBlackHole)
    // A real loss of the routing information falls back to the unknown row after the grace.
    model.apply(.init(state: .recovering(.serviceRestarted), defaultInput: .unresolved))
    #expect(model.routing.isBlackHole)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.routing == AppModel.Routing())
}

@MainActor @Test func routingRowNamesMicBoostAndOnlyChecksItWhileRunning() {
    let model = AppModel(statusGrace: .zero)
    var blackHole = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    blackHole.inputChannels = 2
    blackHole.outputChannels = 2
    model.devices = [blackHole]
    // The engine never started and the microphone permission is denied, but the default
    // input is still the BlackHole: the row names MicBoost, without the check mark.
    model.apply(
        .init(
            state: .error(.microphonePermissionDenied), defaultInput: .init(isBlackHole: false),
            defaultInputName: "BlackHole 2ch"))
    #expect(model.routing == AppModel.Routing(isBlackHole: true))
    #expect(!model.routing.running)
    // Running with the BlackHole as default input: the row is the same plus the check mark.
    model.apply(
        .init(
            state: .running, blackHole: blackHole, defaultInput: .init(isBlackHole: true),
            defaultInputName: "BlackHole 2ch"))
    #expect(model.routing == AppModel.Routing(isBlackHole: true, running: true, canUseMicBoost: true))
}

@MainActor @Test func routingRowShowsUseMicBoostOnlyOnARealDivergence() {
    let model = AppModel(statusGrace: .zero)
    var source = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    source.inputChannels = 1
    var blackHole = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    blackHole.inputChannels = 2
    blackHole.outputChannels = 2
    model.devices = [source, blackHole]
    // Diverged while the engine runs: name and an enabled button.
    model.apply(
        .init(
            state: .running, source: source, blackHole: blackHole, defaultInput: .init(isBlackHole: false),
            defaultInputName: "USB Microphone"))
    #expect(
        model.routing
            == AppModel.Routing(
                isBlackHole: false, name: "USB Microphone", running: true, canUseMicBoost: true))
    // Stopped after a start: the button stays enabled, because clicking it still works.
    model.apply(
        .init(
            state: .stopped, source: source, blackHole: blackHole, defaultInput: .init(isBlackHole: false),
            defaultInputName: "USB Microphone"))
    #expect(!model.routing.running)
    #expect(model.routing.canUseMicBoost)
    // The engine never started: the divergence is shown, but the click would not work.
    model.apply(.init(state: .stopped, defaultInput: .init(isBlackHole: false), defaultInputName: "USB Microphone"))
    #expect(model.routing.name == "USB Microphone")
    #expect(!model.routing.canUseMicBoost)
    // The default input is unknown: nothing is asserted, so there is no button.
    model.apply(.init(state: .running, blackHole: blackHole, defaultInput: .unresolved))
    #expect(model.routing.name == nil)
}

@MainActor @Test func microphoneListHoldsThroughAServiceRestart() async throws {
    let model = AppModel(statusGrace: .milliseconds(100))
    var source = AudioDevice(id: 1, uid: "usb", name: "USB Microphone")
    source.inputChannels = 1
    model.devices = [source]
    #expect(model.sources.map(\.uid) == ["usb"])
    // The restart empties the list for a moment: the last known rows stay.
    model.devices = []
    #expect(model.sources.map(\.uid) == ["usb"])
    model.devices = [source]
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.sources.map(\.uid) == ["usb"])
    // A real absence clears the list after the grace.
    model.devices = []
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.sources.isEmpty)
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

@MainActor @Test func monitorStartFailureTextAndCopyReportIncludeDiagnostics() {
    let model = AppModel()
    var source = AudioDevice(id: 1, uid: "source", name: "Source mic")
    source.transport = kAudioDeviceTransportTypeUSB
    source.sampleRate = 44100
    var output = AudioDevice(id: 2, uid: "output", name: "Wireless output")
    output.transport = kAudioDeviceTransportTypeBluetooth
    output.sampleRate = 44100
    output.availableSampleRates = [.init(44100, 48000)]
    var status = EngineStatus(state: .running, source: source)
    status.monitor = .unavailable(reason: .startFailed, outputName: output.name)
    status.monitorOutput = output
    status.lastMonitorFailure = .init(
        operation: "Start IO", error: .halFailure(-123, "Start IO"), output: output, workingRate: 44100)
    model.apply(status)
    for language in ["en", "pt-BR"] {
        UILanguage.override = language
        #expect(
            model.monitorDescription
                == (language == "en"
                    ? "Couldn't use Wireless output for monitoring."
                    : "Não foi possível usar Wireless output no monitor."))
    }
    UILanguage.override = nil
    #expect(model.report.contains("Source mic | transport=USB | nominal=44100"))
    #expect(model.report.contains("Wireless output | transport=Bluetooth | nominal=44100"))
    #expect(model.report.contains("44100.0...48000.0"))
    #expect(model.report.contains("Start IO: OSStatus -123"))
}

@MainActor @Test func reportNamesAnOffMonitor() {
    let model = AppModel()
    model.apply(EngineStatus(state: .running))
    #expect(model.monitorDescription.isEmpty)
    #expect(model.report.contains("Monitor: off\n"))
}

@MainActor @Test func monitorPanelUsesTotalAndReportSeparatesAddedLatency() {
    let model = AppModel()
    let output = AudioDevice(id: 2, uid: "output", name: "Output")
    var status = EngineStatus(state: .running)
    status.monitor = .active(output: output, addedLatencyMs: 12, totalLatencyMs: 80)
    status.monitorStats.underruns = 2
    status.monitorStats.overruns_full = 3
    status.monitorStats.resets = 4
    status.monitorStats.max_pull = 2048
    status.monitorStats.quantum = 4096
    status.monitorOutputBufferFrames = 512
    status.monitorBufferRequestResult = "256"
    status.monitorHostLatencyMs = 30
    status.monitorVarispeedLatencyMs = 1
    status.monitorAUHALLatencyMs = 2
    model.apply(status)
    #expect(model.monitorDescription.contains("80 ms"))
    #expect(model.monitorAddedLatency.contains("12"))
    #expect(model.report.contains("monitor_underruns: 2"))
    #expect(model.report.contains("monitor_overruns_full: 3"))
    #expect(model.report.contains("monitor_resets: 4"))
    #expect(model.report.contains("monitor_max_pull: 2048"))
    #expect(model.report.contains("monitor_quantum: 4096"))
    #expect(model.report.contains("monitor_output_buffer_requested: 256"))
    #expect(model.report.contains("monitor_output_buffer_actual: 512"))
    #expect(model.report.contains("monitor_host_ms: 30"))
    #expect(model.report.contains("monitor_varispeed_ms: 1"))
    #expect(model.report.contains("monitor_auhal_ms: 2"))
}
