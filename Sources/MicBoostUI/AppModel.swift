import AVFoundation
import AppKit
import CoreAudio
import MicBoostCore
import Observation
import SwiftUI

@MainActor public func localized(_ key: String) -> String {
    if let language = UILanguage.override, let path = Bundle.module.path(forResource: language, ofType: "lproj"),
        let bundle = Bundle(path: path)
    {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return NSLocalizedString(key, bundle: .module, comment: "")
}

/// Language and number format the string catalog resolved to.
@MainActor public enum UILanguage {
    /// Pins the language of `localized(_:)`; `nil` follows the system. The screenshot
    /// renderer pins English so the English README keeps consistent images.
    public static var override: String?
    /// `"en"` or `"pt-BR"`.
    public static var current: String { override ?? Bundle.module.preferredLocalizations.first ?? "en" }
    /// Number locale matching the resolved language, for renders and previews.
    public static var locale: Locale {
        Locale(identifier: current == "pt-BR" ? "pt_BR" : "en_US")
    }
}

@MainActor @Observable public final class AppModel {
    /// Grace before a device absence reaches the panel: when the system audio service
    /// restarts, the devices disappear for a moment and neither the banner nor the
    /// routing row and the microphone list may flash (docs/ui.md "Mensagens de estado").
    public static let absenceGrace: Duration = .milliseconds(1500)

    public var monitorEnabled = false
    public func setMonitorEnabled(_ enabled: Bool) {
        monitorEnabled = enabled
        Task {
            do { try await engine.setMonitorEnabled(enabled) } catch { self.error = error as? EngineError }
        }
    }
    public var monitorAddedLatency: String {
        guard case .active(_, let added, _) = status?.monitor, let added else { return "—" }
        return String(format: "%.1f ms", locale: Self.formatLocale, added)
    }
    public var monitorDescription: String {
        guard let status else { return "" }
        switch status.monitor {
        case .off: return ""
        case .active(let output, _, let latency):
            let format = localized(latency > 50 ? "%@ · high delay (≈ %d ms)" : "%@ · ≈ %d ms")
            return String(format: format, output.name, Int(latency.rounded()))
        case .unavailable(let reason, let name):
            switch reason {
            case .noOutput: return localized("No audio output.")
            case .outputIsLoopback: return String(format: localized("Unavailable with %@."), name ?? "")
            case .formatUnsupported: return String(format: localized("Unsupported format for %@."), name ?? "")
            case .startFailed: return String(format: localized("Couldn't use %@ for monitoring."), name ?? "")
            }
        }
    }
    public var controls = Settings()
    public var status: EngineStatus? {
        didSet {
            syncAbsence()
            syncRouting()
        }
    }
    public var devices: [AudioDevice] = [] {
        didSet {
            syncSources()
            syncRouting()
        }
    }
    public var error: EngineError? {
        didSet { syncAbsence() }
    }
    public var inputDB = -60.0
    public var outputDB = -60.0
    public var limitingUntil = Date.distantPast
    public var panelVisible = false
    public var settingsVisible = false
    /// Device rows of the panel; the last known list is held through the grace.
    public private(set) var sources: [AudioDevice] = []
    /// Routing row of the panel, held through the grace while the default input is unresolved.
    public private(set) var routing = Routing()
    public var expanded = UserDefaults.standard.bool(forKey: "eqExpanded") {
        didSet { UserDefaults.standard.set(expanded, forKey: "eqExpanded") }
    }
    public var onSettings: () -> Void = {}
    public var onQuit: () -> Void = {}
    public var onClose: () -> Void = {}
    public var onUpdate: () -> Void = {}
    /// Called after every meter sample, so the open panel repaints at the poller rate.
    public var onMeters: () -> Void = {}
    /// Number format of the panel rows when the screenshot renderer pins a language.
    public static var formatLocaleOverride: Locale?
    /// Locale the AppKit rows format numbers with.
    public static var formatLocale: Locale { formatLocaleOverride ?? .current }
    /// Microphone authorization source; replaced in tests to simulate the TCC state.
    @ObservationIgnored public var authorization: @MainActor () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    public let store: SettingsStore
    public let engine: EngineController
    private let statusGrace: Duration
    private var meterTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var command: Task<Void, Never>?
    private var pendingAbsence: StatusMessage?
    private var confirmedAbsence: StatusMessage?
    private var absenceTask: Task<Void, Never>?
    private var routingTask: Task<Void, Never>?
    private var sourcesTask: Task<Void, Never>?
    public init(
        store: SettingsStore = SettingsStore(storage: UserDefaultsStorage()),
        statusGrace: Duration = AppModel.absenceGrace
    ) {
        self.store = store
        self.statusGrace = statusGrace
        engine = EngineController(settings: store)
    }
    public static func gainLabel(_ db: Double, locale: Locale = AppModel.formatLocale) -> String {
        let number = db.formatted(.number.locale(locale).precision(.fractionLength(1)))
        return "\(Int((100 * pow(10, db / 20)).rounded()))% (\(db >= 0 ? "+" : "")\(number)dB)"
    }
    public static func gainStep(option: Bool) -> Double { option ? 1 : 0.5 }
    public static func meterFraction(_ db: Double) -> Double {
        guard db.isFinite, db > -60 else { return 0 }
        return min(1, pow(10, db / 20))
    }
    /// Values and selection of a settings picker. The selection is always one of the
    /// values, so a picker can never show an empty value.
    public struct PickerValues: Equatable, Sendable {
        public var values: [Int]
        public var selection: Int
    }
    /// Buffer sizes offered for a source: the allowed sizes it supports, or all of them when
    /// the source does not report a usable range. A persisted size outside the list selects
    /// the closest offered size.
    public static func bufferPicker(sourceBufferRange: AudioRange?, current: Int) -> PickerValues {
        var values = Settings.allowedBufferFrames
        if let range = sourceBufferRange, range.maximum > 0, range.minimum <= range.maximum {
            let supported = values.filter { Double($0) >= range.minimum && Double($0) <= range.maximum }
            if !supported.isEmpty { values = supported }
        }
        let selection =
            values.contains(current) ? current : values.min { abs($0 - current) < abs($1 - current) } ?? current
        return PickerValues(values: values, selection: selection)
    }
    /// Channel options for a source with `channelCount` input channels, and the value that
    /// represents the persisted selection. Mono channels are one-based, `-1` is Mix and `-2`
    /// is Stereo; a channel above the source count maps to the last channel and Stereo maps to
    /// Mono 1 on a single-channel source.
    public static func channelPicker(selection: ChannelSelection, channelCount: Int) -> PickerValues {
        let count = max(1, channelCount)
        var values = Array(1...count)
        values.append(-1)
        if count >= 2 { values.append(-2) }
        let preferred: Int
        switch selection {
        case .auto: preferred = 1
        case .mono(let channel): preferred = min(max(channel, 1), count)
        case .monoMix: preferred = -1
        case .stereo: preferred = count >= 2 ? -2 : 1
        }
        return PickerValues(values: values, selection: preferred)
    }
    public var icon: String {
        if !controls.processingEnabled { return "mic" }
        if error != nil || status?.defaultInput.divergedByUser == true { return "exclamationmark.triangle.fill" }
        return controls.muted ? "mic.slash.fill" : "mic.fill"
    }
    /// One banner at a time, in the priority order of docs/ui.md "Mensagens de estado".
    public enum StatusMessage: Equatable, Sendable {
        case permissionDenied, blackHoleMissing, noSourceSelected
        case sourceLost(String?)
        case formatUnsupported, systemFailure

        public enum Action: Equatable, Sendable {
            case privacySettings, install, retry, noAction
        }
        public var action: Action {
            switch self {
            case .permissionDenied: return .privacySettings
            case .blackHoleMissing: return .install
            case .sourceLost, .formatUnsupported, .noSourceSelected: return .noAction
            case .systemFailure: return .retry
            }
        }
        /// Device absences wait for the grace; failures of the app itself do not.
        var waitsForTheGrace: Bool {
            switch self {
            case .blackHoleMissing, .sourceLost: return true
            case .permissionDenied, .formatUnsupported, .systemFailure, .noSourceSelected: return false
            }
        }
    }
    /// Default-input row of the panel (docs/ui.md "Painel", item 4).
    public struct Routing: Equatable, Sendable {
        /// The default input is the MicBoost output, so the row names it "MicBoost".
        public var isBlackHole: Bool
        /// Name of the current default input when it is not the MicBoost output.
        public var name: String?
        /// The engine is running: the row shows the check mark.
        public var running: Bool
        /// A click on "Use MicBoost" works: the engine already started and the BlackHole is present.
        public var canUseMicBoost: Bool
        public init(isBlackHole: Bool = false, name: String? = nil, running: Bool = false, canUseMicBoost: Bool = false)
        {
            self.isBlackHole = isBlackHole
            self.name = name
            self.running = running
            self.canUseMicBoost = canUseMicBoost
        }
    }
    /// The banner the snapshot calls for: immediate failures right away, device absences after the grace.
    public var statusMessage: StatusMessage? {
        guard let message = currentMessage else { return nil }
        return message.waitsForTheGrace ? confirmedAbsence : message
    }
    /// One message at a time, in the priority order of docs/ui.md "Mensagens de estado".
    private var currentMessage: StatusMessage? {
        if case .recovering(.sourceLost) = status?.state { return .sourceLost(selectedSourceName) }
        if case .recovering(.wakeFailed) = status?.state { return .systemFailure }
        if case .recovering = status?.state { return nil }
        switch error {
        case .microphonePermissionDenied: return .permissionDenied
        case .blackHoleMissing: return .blackHoleMissing
        case .sourceUnavailable: return .sourceLost(selectedSourceName)
        case .noSourceSelected: return .noSourceSelected
        case .formatUnsupported: return .formatUnsupported
        case .halFailure, .invalidArgument: return .systemFailure
        case .none: return nil
        }
    }
    /// Device absence of the snapshot, before the grace that hides short flaps.
    private var absenceMessage: StatusMessage? {
        guard let message = currentMessage, message.waitsForTheGrace else { return nil }
        return message
    }
    /// Starts the grace of a new absence and drops the banner as soon as the condition ends.
    private func syncAbsence() {
        let next = absenceMessage
        if next == confirmedAbsence || next == pendingAbsence { return }
        absenceTask?.cancel()
        absenceTask = nil
        pendingAbsence = next
        confirmedAbsence = nil
        guard let next else { return }
        guard statusGrace != .zero else {
            confirmedAbsence = next
            return
        }
        absenceTask = Task { [weak self, statusGrace] in
            try? await Task.sleep(for: statusGrace)
            guard !Task.isCancelled, let self, self.pendingAbsence == next else { return }
            self.confirmedAbsence = next
        }
    }
    /// A resolved routing row is shown at once; an unresolved one keeps the last known row
    /// through the grace, then falls back to the unknown label.
    private func syncRouting() {
        guard let snapshot = status else { return }
        guard !snapshot.defaultInput.unknown else {
            guard routingTask == nil else { return }
            guard statusGrace != .zero else {
                routing = Routing()
                return
            }
            routingTask = Task { [weak self, statusGrace] in
                try? await Task.sleep(for: statusGrace)
                guard !Task.isCancelled, let self else { return }
                self.routingTask = nil
                self.routing = Routing()
            }
            return
        }
        routingTask?.cancel()
        routingTask = nil
        let isBlackHole =
            snapshot.defaultInput.isBlackHole || isBlackHoleDefaultInput(named: snapshot.defaultInputName)
        routing = Routing(
            isBlackHole: isBlackHole,
            name: isBlackHole ? nil : snapshot.defaultInputName,
            running: snapshot.state == .running,
            canUseMicBoost: snapshot.blackHole != nil && devices.contains { $0.isBlackHole2ch && $0.alive })
    }
    /// Before the engine starts it has no destination, so the enumerated devices identify
    /// the default input by name (docs/ui.md "Painel", item 4).
    private func isBlackHoleDefaultInput(named name: String?) -> Bool {
        guard let name else { return false }
        return devices.contains { $0.isBlackHole2ch && $0.name == name }
    }
    /// Keeps the last known microphone list through a brief disappearance of every device.
    private func syncSources() {
        let next = devices.filter { $0.alive && $0.isEligible(in: devices) }
        if !next.isEmpty || sources.isEmpty {
            sourcesTask?.cancel()
            sourcesTask = nil
            sources = next
            return
        }
        guard sourcesTask == nil else { return }
        guard statusGrace != .zero else {
            sources = next
            return
        }
        sourcesTask = Task { [weak self, statusGrace] in
            try? await Task.sleep(for: statusGrace)
            guard !Task.isCancelled, let self else { return }
            self.sourcesTask = nil
            self.sources = next
        }
    }
    public var message: String? {
        switch statusMessage {
        case .permissionDenied: return localized("Microphone access denied.")
        case .blackHoleMissing: return localized("BlackHole 2ch not found.")
        case .noSourceSelected: return localized("Choose a microphone in the list.")
        case .sourceLost(let name?):
            return String.localizedStringWithFormat(
                localized("%@ disconnected. Audio resumes when it is reconnected."), name)
        case .sourceLost(nil): return localized("Microphone disconnected. Audio resumes when reconnected.")
        case .formatUnsupported: return localized("Microphone format unsupported.")
        case .systemFailure: return localized("System audio failed.")
        case nil: return nil
        }
    }
    /// UID of the system default input, as Core Audio reports it.
    public var systemDefaultInputUID: () -> String? = { AVCaptureDevice.default(for: .audio)?.uniqueID }
    /// The microphone a first launch starts with: the system default input when it is an
    /// eligible source, otherwise the built-in microphone, otherwise the first source
    /// (docs/ui.md "Painel", item 8).
    public static func initialSource(in sources: [AudioDevice], defaultUID: String?) -> AudioDevice? {
        sources.first { $0.uid == defaultUID }
            ?? sources.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? sources.first
    }
    public func launch() async {
        controls = await store.current
        await refresh()
        if authorization() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if controls.selectedInputUID == nil,
            let device = Self.initialSource(in: sources, defaultUID: systemDefaultInputUID())
        {
            controls.selectedInputUID = device.uid
            await store.update { $0.selectedInputUID = device.uid }
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
        rememberSourceNames(devices)
        onUpdate()
    }
    /// Keeps the last name each device reported, so a source that is absent keeps its name
    /// in the list and in the banner, even after a relaunch (docs/ui.md "Painel").
    func rememberSourceNames(_ devices: [AudioDevice]) {
        var names = controls.knownSourceNames
        for device in devices where !device.name.isEmpty {
            names[device.uid] = device.name
        }
        guard names != controls.knownSourceNames else { return }
        let recorded = names
        controls.knownSourceNames = recorded
        Task { await store.update { $0.knownSourceNames.merge(recorded) { _, new in new } } }
    }
    /// Last known name of the selected source: the device itself reports it while it is
    /// present, and the persisted map covers the app starting while it is absent.
    public var selectedSourceName: String? {
        guard let uid = controls.selectedInputUID else { return status?.source?.name }
        if let source = status?.source, source.uid == uid { return source.name }
        return controls.knownSourceNames[uid]
    }
    /// Row of the selected source that is not in the device list: the last known name,
    /// never its UID, or a generic label when the name was never seen (docs/ui.md "Painel").
    public var disconnectedSourceLabel: String {
        guard let name = selectedSourceName else { return localized("Disconnected microphone") }
        return String.localizedStringWithFormat(localized("%@ (disconnected)"), name)
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
                onMeters()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    public var report: String {
        guard let status else { return localized("Stopped") }
        func deviceDetails(_ device: AudioDevice?) -> String {
            guard let device else { return "—" }
            let transport: String
            switch device.transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = "Bluetooth"
            case kAudioDeviceTransportTypeUSB: transport = "USB"
            case kAudioDeviceTransportTypeBuiltIn: transport = "Built-in"
            case kAudioDeviceTransportTypeAggregate: transport = "Aggregate"
            default: transport = "\(device.transport)"
            }
            let rates = device.supportedRates.map { "\($0.minimum)...\($0.maximum)" }.joined(separator: ", ")
            return "\(device.name) | transport=\(transport) | nominal=\(device.sampleRate) Hz | available=\(rates)"
        }
        let failure =
            status.lastMonitorFailure.map { failure in
                if case .halFailure(let code, _) = failure.error { return "\(failure.operation): OSStatus \(code)" }
                return "\(failure.operation): \(failure.error)"
            } ?? "—"
        return
            "Source: \(deviceDetails(status.source))\nMonitor output: \(deviceDetails(status.monitorOutput))\nLast monitor failure: \(failure)\n"
            + "\(status.sampleRate) Hz\n\(status.bufferFrames) frames\n\(status.reportedLatencyMs) ms\nMonitor: \(monitorDescription)\nMonitor added: \(monitorAddedLatency)\nmonitor_fill: \(status.monitorStats.fill)\nmonitor_correction_ppm: \(status.monitorStats.correction * 1e6)\nmonitor_underruns: \(status.monitorStats.underruns)\nmonitor_overruns: \(status.monitorStats.overruns)\nOverloads: \(status.overloads)\ninput_missing: \(status.inputMissing)\nnonfinite_resets: \(status.nonfiniteResets)"
    }
    public func shutdown() async throws {
        monitor?.cancel()
        meterTask?.cancel()
        await command?.value
        try await engine.stop()
        await store.flush()
    }
}
