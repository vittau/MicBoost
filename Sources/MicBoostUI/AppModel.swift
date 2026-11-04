import AVFoundation
import AppKit
import MicBoostCore
import Observation
import SwiftUI

public func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// Language and number format the string catalog resolved to.
public enum UILanguage {
    /// `"en"` or `"pt-BR"`.
    public static var current: String { Bundle.module.preferredLocalizations.first ?? "en" }
    /// Number locale matching the resolved language, for renders and previews.
    public static var locale: Locale {
        Locale(identifier: current == "pt-BR" ? "pt_BR" : "en_US")
    }
}

@MainActor @Observable public final class AppModel {
    public var controls = Settings()
    public var status: EngineStatus?
    public var devices: [AudioDevice] = []
    public var error: EngineError?
    public var inputDB = -60.0
    public var outputDB = -60.0
    public var limitingUntil = Date.distantPast
    public var panelVisible = false
    public var settingsVisible = false
    public var expanded = UserDefaults.standard.bool(forKey: "eqExpanded") {
        didSet { UserDefaults.standard.set(expanded, forKey: "eqExpanded") }
    }
    public var onSettings: () -> Void = {}
    public var onQuit: () -> Void = {}
    public var onClose: () -> Void = {}
    public var onUpdate: () -> Void = {}
    /// Microphone authorization source; replaced in tests to simulate the TCC state.
    @ObservationIgnored public var authorization: @MainActor () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    public let store: SettingsStore
    public let engine: EngineController
    private var meterTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var command: Task<Void, Never>?
    public init(store: SettingsStore = SettingsStore(storage: UserDefaultsStorage())) {
        self.store = store
        engine = EngineController(settings: store)
    }
    public static func gainLabel(_ db: Double, locale: Locale = .current) -> String {
        let number = db.formatted(.number.locale(locale).precision(.fractionLength(1)))
        return "\(Int((100 * pow(10, db / 20)).rounded()))% (\(db >= 0 ? "+" : "")\(number)dB)"
    }
    public static func gainStep(option: Bool) -> Double { option ? 1 : 0.5 }
    public static func meterFraction(_ db: Double) -> Double {
        guard db.isFinite, db > -60 else { return 0 }
        return min(1, pow(10, db / 20))
    }
    public var icon: String {
        if !controls.processingEnabled { return "mic" }
        if error != nil || status?.defaultInput.divergedByUser == true { return "exclamationmark.triangle.fill" }
        return controls.muted ? "mic.slash.fill" : "mic.fill"
    }
    /// One banner at a time, in the priority order of docs/ui.md "Mensagens de estado".
    public enum StatusMessage: Equatable, Sendable {
        case permissionDenied, blackHoleMissing
        case sourceLost(String?)
        case formatUnsupported, systemFailure

        public enum Action: Equatable, Sendable {
            case privacySettings, install, retry, noAction
        }
        public var action: Action {
            switch self {
            case .permissionDenied: return .privacySettings
            case .blackHoleMissing: return .install
            case .sourceLost, .formatUnsupported: return .noAction
            case .systemFailure: return .retry
            }
        }
    }
    public var statusMessage: StatusMessage? {
        if case .recovering(.sourceLost) = status?.state { return .sourceLost(status?.source?.name) }
        if case .recovering(.wakeFailed) = status?.state { return .systemFailure }
        if case .recovering = status?.state { return nil }
        switch error {
        case .microphonePermissionDenied: return .permissionDenied
        case .blackHoleMissing: return .blackHoleMissing
        case .sourceUnavailable, .noSourceSelected: return .sourceLost(status?.source?.name)
        case .formatUnsupported: return .formatUnsupported
        case .some: return .systemFailure
        case .none: return nil
        }
    }
    public var message: String? {
        switch statusMessage {
        case .permissionDenied: return localized("Microphone access denied.")
        case .blackHoleMissing: return localized("BlackHole 2ch not found.")
        case .sourceLost(let name?):
            return String.localizedStringWithFormat(
                localized("%@ disconnected. Audio resumes when it is reconnected."), name)
        case .sourceLost(nil): return localized("Microphone disconnected. Audio resumes when reconnected.")
        case .formatUnsupported: return localized("Microphone format unsupported.")
        case .systemFailure: return localized("System audio failed.")
        case nil: return nil
        }
    }
    public func launch() async {
        controls = await store.current
        await refresh()
        if authorization() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if controls.processingEnabled { await start() }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    /// The microphone permission can change while the app is in the background, so the
    /// authorization is re-checked every time the app becomes active.
    public func applicationDidBecomeActive() {
        let status = authorization()
        if status == .denied || status == .restricted {
            error = controls.processingEnabled ? .microphonePermissionDenied : nil
            return
        }
        guard error == .microphonePermissionDenied else { return }
        error = nil
        retry()
    }
    public func refresh() async {
        apply(await engine.status())
        devices = (try? await engine.availableDevices()) ?? []
        onUpdate()
    }
    /// Applies an engine snapshot; also used by tests and by the screenshot renderer.
    public func apply(_ snapshot: EngineStatus) {
        status = snapshot
        if case .error(let value) = snapshot.state {
            error = value
        } else if snapshot.state == .running {
            error = nil
        } else if snapshot.state == .stopped, !controls.processingEnabled {
            error = nil
        }
    }
    public var sources: [AudioDevice] { devices.filter { $0.alive && $0.isEligible(in: devices) } }
    private func start() async {
        guard let uid = controls.selectedInputUID else {
            error = .noSourceSelected
            return
        }
        do { try await engine.start(inputUID: uid) } catch { self.error = error as? EngineError }
        await refresh()
    }
    public func finishCommands() async { await command?.value }
    public func processing(_ enabled: Bool) {
        controls.processingEnabled = enabled
        let previous = command
        command = Task {
            await previous?.value
            await store.update { $0.processingEnabled = enabled }
            if enabled {
                await start()
            } else {
                do {
                    try await engine.stop()
                    error = nil
                } catch { self.error = error as? EngineError }
                await refresh()
            }
        }
    }
    public func select(_ device: AudioDevice) {
        controls.selectedInputUID = device.uid
        Task {
            await store.update { $0.selectedInputUID = device.uid }
            if controls.processingEnabled { await start() }
        }
    }
    public func gain(_ value: Double) {
        controls.gainDB = min(24, max(-12, (value * 2).rounded() / 2))
        let db = controls.gainDB
        Task { await engine.setGain(db: db) }
    }
    public func mute() {
        controls.muted.toggle()
        let muted = controls.muted
        Task { await engine.setMuted(muted) }
    }
    public func eq() {
        controls.eq.mid.q = (controls.eq.mid.q * 10).rounded() / 10
        controls.eq = controls.eq.sanitized()
        let eq = controls.eq
        Task {
            await engine.setEQEnabled(eq.enabled)
            await engine.setBand(.low, frequency: eq.low.frequency, gainDB: eq.low.gainDB)
            await engine.setBand(.mid, frequency: eq.mid.frequency, gainDB: eq.mid.gainDB, q: eq.mid.q)
            await engine.setBand(.high, frequency: eq.high.frequency, gainDB: eq.high.gainDB)
        }
    }
    public func voicePreset() {
        let enabled = controls.eq.enabled
        controls.eq = EQSettings()
        controls.eq.enabled = enabled
        eq()
    }
    public func reset() {
        let enabled = controls.eq.enabled
        controls.eq = EQSettings()
        controls.eq.low.gainDB = 0
        controls.eq.mid.gainDB = 0
        controls.eq.high.gainDB = 0
        controls.eq.enabled = enabled
        eq()
    }
    public func useBlackHole() {
        Task {
            try? await engine.useBlackHole()
            await refresh()
        }
    }
    public func retry() {
        guard controls.processingEnabled else { return }
        let previous = command
        command = Task {
            await previous?.value
            await start()
        }
    }
    public func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        meterTask?.cancel()
        guard visible else { return }
        meterTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let meter = await engine.meters()
                let now = Date()
                let decay = now.timeIntervalSince(last) * 20
                last = now
                let direct = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let input = max(-60, 20 * log10(max(Double(meter.inputPeak), 0.001)))
                let output = max(-60, 20 * log10(max(Double(meter.outputPeak), 0.001)))
                inputDB = direct ? input : max(input, inputDB - decay)
                outputDB = direct ? output : max(output, outputDB - decay)
                if meter.gainReductionDB > 1 { limitingUntil = now.addingTimeInterval(0.3) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    public var report: String {
        guard let status else { return localized("Stopped") }
        return
            "\(status.sampleRate) Hz\n\(status.bufferFrames) frames\n\(status.reportedLatencyMs) ms\nOverloads: \(status.overloads)\ninput_missing: \(status.inputMissing)\nnonfinite_resets: \(status.nonfiniteResets)"
    }
    public func shutdown() async throws {
        monitor?.cancel()
        meterTask?.cancel()
        await command?.value
        try await engine.stop()
        await store.flush()
    }
}
