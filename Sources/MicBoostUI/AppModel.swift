import AVFoundation
import AppKit
import MicBoostCore
import Observation
import SwiftUI

public func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
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
        if error != nil || status?.defaultInput.divergedByUser == true { return "exclamationmark.triangle.fill" }
        if !controls.processingEnabled { return "mic" }
        return controls.muted ? "mic.slash.fill" : "mic.fill"
    }
    public var message: String? {
        switch error {
        case .microphonePermissionDenied: return localized("Microphone access denied.")
        case .blackHoleMissing: return localized("BlackHole 2ch not found.")
        case .sourceUnavailable, .noSourceSelected:
            return localized("Microphone disconnected. Audio resumes when reconnected.")
        case .formatUnsupported: return localized("Microphone format unsupported.")
        case .some: return localized("System audio failed.")
        case .none:
            if case .recovering = status?.state {
                return localized("Microphone disconnected. Audio resumes when reconnected.")
            }
            return nil
        }
    }
    public func launch() async {
        controls = await store.current
        await refresh()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if controls.processingEnabled {
            await start()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                error = .microphonePermissionDenied
            } else if !devices.contains(where: { $0.isBlackHole2ch && $0.alive }) {
                error = .blackHoleMissing
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    public func refresh() async {
        status = await engine.status()
        devices = (try? await engine.availableDevices()) ?? []
        if case .error(let value) = status?.state { error = value } else if status?.state == .running { error = nil }
        onUpdate()
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
        Task { await start() }
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
