import CoreAudio
import Dispatch
import Foundation
import MicBoostDSP
import os

public enum RecoveryReason: Sendable, Equatable {
    /// The selected source disappeared or stopped being alive.
    case sourceLost
    /// The source or the BlackHole changed rate or stream configuration.
    case formatChanged
    /// The audio server restarted; every cached object ID is stale.
    case serviceRestarted
    /// The engine stopped for the system sleep.
    case sleep
    /// The single start attempt after a wake failed.
    case wakeFailed
}
public enum EngineState: Sendable, Equatable {
    case stopped, starting, running
    case recovering(RecoveryReason)
    case error(EngineError)
}
/// Short stable form of the engine state for the unified log.
extension EngineState {
    var logName: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .recovering(let reason):
            switch reason {
            case .sourceLost: "recovering.sourceLost"
            case .formatChanged: "recovering.formatChanged"
            case .serviceRestarted: "recovering.serviceRestarted"
            case .sleep: "recovering.sleep"
            case .wakeFailed: "recovering.wakeFailed"
            }
        case .error(let error): "error(\(error))"
        }
    }
}
public enum MonitorUnavailableReason: Sendable, Equatable {
    case noOutput, outputIsLoopback, formatUnsupported, startFailed
}
public enum MonitorStatus: Sendable, Equatable {
    case off
    case active(output: AudioDevice, addedLatencyMs: Double?, totalLatencyMs: Double)
    case unavailable(reason: MonitorUnavailableReason, outputName: String?)
}
public struct MonitorFailure: Sendable, Equatable {
    public var operation: String
    public var error: EngineError
    public var output: AudioDevice
    public var workingRate: Double
    public init(operation: String, error: EngineError, output: AudioDevice, workingRate: Double) {
        self.operation = operation
        self.error = error
        self.output = output
        self.workingRate = workingRate
    }
}
public struct EngineStatus: Sendable {
    public var monitorOutput: AudioDevice?
    public var lastMonitorFailure: MonitorFailure?
    public var monitor: MonitorStatus = .off
    public var monitorStats = mb_monitor_stats()
    public var monitorBufferRequestResult = "none"
    public var monitorOutputBufferFrames: UInt32 = 0
    public var monitorOutputBufferReadFromAUHAL = false
    public var monitorPreferredBufferFrames: UInt32 = 0
    public var monitorHostLatencyMs: Double?
    public var monitorVarispeedLatencyMs = 0.0
    public var monitorAUHALLatencyMs = 0.0
    public var state: EngineState
    public var source: AudioDevice?
    public var blackHole: AudioDevice?
    public var defaultInput: DefaultInputStatus
    public var defaultInputName: String?
    public var sampleRate: Double
    public var bufferFrames: UInt32
    public var reportedLatencyMs: Double
    public var overloads: UInt64
    public var cycles: UInt64
    public var inputMissing: UInt64
    public var nonfiniteResets: UInt64
    public var ioDeltaHost: UInt64
    public init(
        state: EngineState = .stopped, source: AudioDevice? = nil, blackHole: AudioDevice? = nil,
        defaultInput: DefaultInputStatus = .unresolved, defaultInputName: String? = nil,
        sampleRate: Double = 0, bufferFrames: UInt32 = 0, reportedLatencyMs: Double = 0,
        overloads: UInt64 = 0, cycles: UInt64 = 0, inputMissing: UInt64 = 0,
        nonfiniteResets: UInt64 = 0, ioDeltaHost: UInt64 = 0
    ) {
        self.state = state
        self.source = source
        self.blackHole = blackHole
        self.defaultInput = defaultInput
        self.defaultInputName = defaultInputName
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.reportedLatencyMs = reportedLatencyMs
        self.overloads = overloads
        self.cycles = cycles
        self.inputMissing = inputMissing
        self.nonfiniteResets = nonfiniteResets
        self.ioDeltaHost = ioDeltaHost
    }
}
public enum EQBand: Sendable { case low, mid, high }
public struct MetersSnapshot: Sendable {
    public var inputPeak: Float
    public var outputPeak: Float
    public var gainReductionDB: Float
    public var inputClipped: Bool
}
public actor EngineController {
    private let queue = DispatchSerialQueue(label: "io.github.vittau.MicBoost.engine")
    nonisolated public var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let log = Logger(subsystem: "io.github.vittau.MicBoost", category: "engine")
    private let settings: SettingsStore
    private var controls = Settings()
    private lazy var routingManager = DefaultInputManager(hardware: hardware, settings: settings)
    private var channelSelection: ChannelSelection = .mono(channel: 1)
    private var monitorEnabled = false
    private var diagnosticMonitorSilent = false
    private var monitorOutputUID: String?
    private var lastMonitorFailure: MonitorFailure?
    private var monitorStatus: MonitorStatus = .off
    private var monitorOutput: AudioDevice?
    private var monitorContext: OpaquePointer?
    private var monitorSession: (any MonitorSession)?
    private var monitorTokens: [UUID] = []
    private var monitorPending: Task<Void, Never>?
    private var monitorTimer: Task<Void, Never>?
    private var monitorPI = mb_monitor_pi()
    private var monitorCorrection = 0.0
    private var monitorMetricsDate = Date.distantPast
    private var monitorWindowMin = UInt32.max
    private var monitorWindowMax: UInt32 = 0
    private var monitorWindowPull: UInt32 = 0
    private var monitorSecondMin: UInt32 = 0
    private var monitorSecondMax: UInt32 = 0
    private var monitorSecondPull: UInt32 = 0
    private var monitorSettleUntil = Date.distantPast
    /// The resolved candidate is retained even when monitoring is unavailable.
    private var resolvedMonitorOutput: AudioDevice?
    private var resolvedMonitorEligible = false
    private var forceRebuild = false
    private var pendingReason: RecoveryReason = .formatChanged
    private let hardware: any EngineHardware
    private var state: EngineState = .stopped
    private var hasRun = false
    private var sleeping = false
    private var selected: String?
    private var requested: UInt32 = 256
    private var source: AudioDevice?
    private var destination: AudioDevice?
    private var aggregate: AudioObjectID?
    private var proc: AudioDeviceIOProcID?
    private var engine: OpaquePointer?
    private var completedCounters = mb_counters()
    private var reportedFrames: UInt32 = 0
    private var buffer: UInt32 = 0
    private var overloads: UInt64 = 0
    private var tokens: [UUID] = []
    private var systemTokens: [UUID] = []
    private var pending: Task<Void, Never>?
    private var defaultToken: UUID?
    /// Rate each device had before MicBoost changed it, keyed by UID.
    private var previousRates: [String: Double] = [:]
    /// Rate MicBoost applied to each device, keyed by UID.
    private var appliedRates: [String: Double] = [:]
    /// Format notifications that arrive right after a build are the engine's own start.
    private var settleUntil = Date.distantPast
    private var formatGeneration: UInt64 = 0
    /// Delay before the single start attempt after a wake.
    private let wakeDelay: Duration
    private var stateObserver: (@Sendable (EngineState) -> Void)?
    public init(
        settings: SettingsStore = SettingsStore(storage: UserDefaultsStorage()), wakeDelay: Duration = .seconds(1)
    ) {
        hardware = CoreAudioHardware()
        self.settings = settings
        self.wakeDelay = wakeDelay
    }
    public init(
        hardware: sending any EngineHardware, settings: SettingsStore = SettingsStore(storage: UserDefaultsStorage()),
        wakeDelay: Duration = .seconds(1)
    ) {
        self.hardware = hardware
        self.settings = settings
        self.wakeDelay = wakeDelay
    }
    /// Receives every state change on the engine queue; used by tests and by `micboost-diag`.
    public func observe(_ observer: (@Sendable (EngineState) -> Void)?) { stateObserver = observer }
    private func setState(_ new: EngineState) {
        guard state != new else { return }
        state = new
        log.notice("state=\(new.logName, privacy: .public) source=\(self.selected ?? "-", privacy: .public)")
        stateObserver?(new)
    }

    /// Working rate shared by source and destination: 48 kHz when available, otherwise
    /// the highest rate below it, otherwise the lowest above it.
    public static func workingSampleRate(source: [AudioRange], destination: [AudioRange]) -> Double? {
        func supports(_ ranges: [AudioRange], _ rate: Double) -> Bool {
            ranges.contains { $0.minimum <= rate && rate <= $0.maximum }
        }
        var candidates: Set<Double> = [48000]
        for range in source + destination {
            candidates.insert(range.minimum)
            candidates.insert(range.maximum)
        }
        let common = candidates.filter { $0 > 0 && supports(source, $0) && supports(destination, $0) }.sorted()
        if common.contains(48000) { return 48000 }
        if let below = common.last(where: { $0 < 48000 }) { return below }
        return common.first
    }

    public func start(inputUID: String, bufferFrames: UInt32? = nil) async throws {
        try subscribeSystem()
        let stored = await settings.current
        controls = stored
        let bufferFrames = bufferFrames ?? UInt32(stored.bufferFrames)
        channelSelection = stored.channelSelectionByUID[inputUID] ?? .mono(channel: 1)
        guard bufferFrames > 0 else { throw EngineError.invalidArgument("Buffer must be positive") }
        let previousSelection = selected
        try tearDown()
        // A source switch is a voluntary stop of the previous bridge: give its devices
        // their rates back before the new source imposes its own working rate.
        if let previousSelection, previousSelection != inputUID { restoreRates() }
        hasRun = false
        sleeping = false
        selected = inputUID
        requested = bufferFrames
        try await build()
    }
    private func subscribeSystem() throws {
        guard systemTokens.isEmpty else { return }
        let object = AudioObjectID(kAudioObjectSystemObject)
        systemTokens.append(
            try hardware.addListener(.init(object, kAudioHardwarePropertyDevices), queue: queue) { [weak self] in
                Task { await self?.changed() }
            })
        systemTokens.append(
            try hardware.addListener(
                .init(object, kAudioHardwarePropertyServiceRestarted), queue: queue
            ) { [weak self] in
                Task { await self?.changed(force: true, reason: .serviceRestarted) }
            })
        systemTokens.append(
            try hardware.addListener(.init(object, kAudioHardwarePropertyDefaultOutputDevice), queue: queue) {
                [weak self] in
                Task { await self?.monitorChanged() }
            })
        if defaultToken == nil {
            defaultToken = try hardware.addListener(
                .init(object, kAudioHardwarePropertyDefaultInputDevice), queue: queue
            ) { [weak self] in
                Task { try? await self?.defaultChanged() }
            }
        }
    }
    /// Diagnostic override; never changes the system default output.
    public func setDiagnosticMonitorSilent(_ silent: Bool) { diagnosticMonitorSilent = silent }
    public func setMonitorOutput(uid: String?) { monitorOutputUID = uid }
    public func setMonitorEnabled(_ enabled: Bool) async throws {
        guard monitorEnabled != enabled else { return }
        monitorEnabled = enabled
        guard state == .running, !sleeping else { return }
        do {
            try stopMonitor()
            if enabled { await startMonitor() }
        } catch {
            recordMonitorFailure(error, operation: "Stop monitor")
            monitorStatus = .unavailable(reason: .startFailed, outputName: resolvedMonitorOutput?.name)
            logMonitorUnavailable()
        }
    }
    private func build(bluetoothProfile: AudioDevice? = nil) async throws {
        setState(.starting)
        do {
            guard hardware.microphoneAuthorized else {
                throw EngineError.microphonePermissionDenied
            }
            let devices = try hardware.devices()
            guard var blackHole = devices.first(where: { $0.isBlackHole2ch && $0.alive }) else {
                setState(.error(.blackHoleMissing))
                return
            }
            guard
                var source = devices.first(where: {
                    $0.uid == selected && $0.alive && $0.isEligible(in: devices)
                })
            else {
                setState(hasRun ? .recovering(.sourceLost) : .error(.sourceUnavailable(selected ?? "")))
                return
            }
            if let profile = bluetoothProfile, profile.uid == source.uid, Self.isBluetooth(source) {
                let currentID = source.id
                source = profile
                source.id = currentID
            }
            guard
                let working = Self.workingSampleRate(
                    source: source.supportedRates, destination: blackHole.supportedRates)
            else {
                throw EngineError.formatUnsupported
            }
            if source.sampleRate != working {
                recordRate(uid: source.uid, current: source.sampleRate, target: working)
                try hardware.setRate(source.id, rate: working)
                source.sampleRate = working
            }
            if blackHole.sampleRate != working {
                recordRate(uid: blackHole.uid, current: blackHole.sampleRate, target: working)
                try hardware.setRate(blackHole.id, rate: working)
                blackHole.sampleRate = working
            }
            self.source = source
            destination = blackHole
            for stale in devices where stale.uid == AggregateBuilder.uid {
                try hardware.destroyAggregate(stale.id)
            }
            let id = try hardware.createAggregate(source: source.uid, destination: blackHole.uid)
            aggregate = id
            let deadline = Date().addingTimeInterval(2)
            while !(try hardware.devices().contains(where: { $0.id == id && $0.alive })) {
                guard Date() < deadline else { throw EngineError.halFailure(-1, "Wait for aggregate") }
                try await Task.sleep(for: .milliseconds(10))
            }
            buffer = try hardware.setBuffer(id, frames: requested)
            let sourceLayout = try hardware.layout(source.id)
            let destinationLayout = try hardware.layout(blackHole.id)
            var routing = try AggregateBuilder.routing(source: sourceLayout, destination: destinationLayout)
            guard let context = mb_engine_create(try hardware.maximumFrames(id, buffer: buffer), source.sampleRate)
            else { throw EngineError.formatUnsupported }
            engine = context
            guard mb_engine_configure(context, &routing) == 0 else { throw EngineError.formatUnsupported }
            setChannelSelection(channelSelection)
            applyControls()
            let io = try hardware.createIO(id, context: context)
            proc = io
            try hardware.streamUsage(
                id, proc: io, input: true,
                enabled: Array(repeating: true, count: sourceLayout.inputStreams)
                    + Array(repeating: false, count: destinationLayout.inputStreams))
            try hardware.streamUsage(
                id, proc: io, input: false,
                enabled: Array(repeating: false, count: sourceLayout.outputStreams)
                    + Array(repeating: true, count: destinationLayout.outputStreams))
            try hardware.startIO(id, proc: io)
            let generation = formatGeneration
            for device in [source, blackHole] {
                tokens.append(
                    try hardware.addListener(.init(device.id, kAudioDevicePropertyDeviceIsAlive), queue: queue) {
                        [weak self] in
                        Task { await self?.changed() }
                    })
                let uid = device.uid
                tokens.append(
                    try hardware.addListener(.init(device.id, kAudioDevicePropertyNominalSampleRate), queue: queue) {
                        [weak self] in
                        Task { await self?.rateChanged(uid: uid, generation: generation) }
                    })
            }
            for device in [source, blackHole] {
                let uid = device.uid
                for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                    tokens.append(
                        try hardware.addListener(
                            .init(device.id, kAudioDevicePropertyStreamConfiguration, scope), queue: queue
                        ) { [weak self] in
                            Task { await self?.formatEvent(uid: uid, generation: generation) }
                        })
                }
            }
            tokens.append(
                try hardware.addListener(.init(id, kAudioDeviceProcessorOverload), queue: queue) { [weak self] in
                    Task { await self?.overloaded() }
                })
            reportedFrames =
                try hardware.latencyFrames(source.id, scope: kAudioObjectPropertyScopeInput)
                + hardware.latencyFrames(blackHole.id, scope: kAudioObjectPropertyScopeOutput)
                + hardware.latencyFrames(id, scope: kAudioObjectPropertyScopeInput) + buffer
            hasRun = true
            setState(.running)
            settleUntil = Date().addingTimeInterval(Self.isBluetooth(source) ? 3 : 0.3)
            try await routingManager.engineDidStart(blackHole: blackHole)
            await startMonitor()
            if Self.isBluetooth(source), let current = try hardware.devices().first(where: { $0.uid == source.uid }),
                current.sampleRate != source.sampleRate
            {
                changed()
            }
        } catch {
            setState(.error((error as? EngineError) ?? .invalidArgument(String(describing: error))))
            try tearDown()
            throw error
        }
    }
    private func monitorSnapshot() -> MonitorStatus {
        guard case .active = monitorStatus else { return monitorStatus }
        guard let output = monitorOutput, let context = monitorContext, let session = monitorSession else {
            return monitorStatus
        }
        var stats = mb_monitor_stats()
        mb_monitor_peek(context, &stats)
        let added =
            stats.latency_host > 0
            ? MonitorLatency.addedMilliseconds(
                hostMilliseconds: Self.hostMilliseconds(stats.latency_host),
                varispeedSeconds: session.varispeedLatencySeconds, auhalSeconds: session.auhalLatencySeconds) : nil
        let physical = (try? hardware.latencyFrames(source?.id ?? 0, scope: kAudioObjectPropertyScopeInput)) ?? 0
        let outFrames = (try? hardware.latencyFrames(output.id, scope: kAudioObjectPropertyScopeOutput)) ?? 0
        let total =
            Double(physical) * 1000 / (source?.sampleRate ?? 48000)
            + (added ?? 0) + Double(outFrames) * 1000 / output.sampleRate
        return .active(output: output, addedLatencyMs: added, totalLatencyMs: total)
    }
    private static func hostMilliseconds(_ ticks: UInt64) -> Double {
        var time = mach_timebase_info_data_t()
        mach_timebase_info(&time)
        return Double(ticks) * Double(time.numer) / Double(time.denom) / 1e6
    }
    private func startMonitor() async {
        guard monitorEnabled, state == .running, let engine, monitorContext == nil else { return }
        lastMonitorFailure = nil
        var operation = "Resolve monitor output"
        do {
            let devices = try hardware.devices()
            resolvedMonitorOutput = currentMonitorOutput(in: devices)
            resolvedMonitorEligible = monitorEligible(resolvedMonitorOutput, in: devices)
            guard let output = resolvedMonitorOutput, output.outputChannels > 0 else {
                monitorStatus = .unavailable(reason: .noOutput, outputName: resolvedMonitorOutput?.name)
                logMonitorUnavailable()
                return
            }
            guard resolvedMonitorEligible else {
                monitorStatus = .unavailable(reason: .outputIsLoopback, outputName: output.name)
                logMonitorUnavailable()
                return
            }
            guard output.sampleRate > 0, output.sampleRate.isFinite else { throw EngineError.formatUnsupported }
            operation = "Create monitor ring context"
            let rate = source?.sampleRate ?? 48000
            let target = 1.0
            guard let context = mb_monitor_create(engine, rate, 1) else { throw EngineError.formatUnsupported }
            monitorContext = context
            monitorMetricsDate = Date()
            monitorWindowMin = UInt32.max
            monitorWindowMax = 0
            monitorWindowPull = 0
            monitorSecondMin = UInt32(target.rounded(.up))
            monitorSecondMax = monitorSecondMin
            monitorSecondPull = 0
            mb_monitor_set_silent(context, diagnosticMonitorSilent)
            operation = "Create and start monitor units"
            let shared = output.sharesDevice(with: [source, destination].compactMap { $0 }, in: devices)
            let preferred = MonitorLatency.preferredBufferFrames(
                engineFrames: buffer, engineRate: rate, outputRate: output.sampleRate, range: output.bufferRange)
            monitorSession = try hardware.createMonitor(
                output, context: context, rate: rate,
                bufferPolicy: shared ? .sharedWithSource : .request(preferred))
            if let session = monitorSession {
                mb_monitor_set_target_base(
                    context, buffer, UInt32(ceil(Double(session.outputBufferFrames) * rate / output.sampleRate)))
                var initial = mb_monitor_stats()
                mb_monitor_peek(context, &initial)
                monitorSecondMin = initial.fill
                monitorSecondMax = initial.fill
            }
            monitorOutput = output
            monitorPI = mb_monitor_pi()
            mb_engine_set_monitor_enabled(engine, true)
            try monitorSession?.start()
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
                monitorTokens.append(
                    try hardware.addListener(.init(output.id, selector), queue: queue) { [weak self] in
                        Task { await self?.monitorChanged() }
                    })
            }
            monitorTokens.append(
                try hardware.addListener(
                    .init(output.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                    queue: queue
                ) { [weak self] in
                    Task { await self?.monitorChanged(force: true) }
                })
            monitorSettleUntil = Date().addingTimeInterval(0.3)
            monitorStatus = .active(output: output, addedLatencyMs: nil, totalLatencyMs: 0)
            monitorTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    await self?.monitorTick()
                }
            }
        } catch {
            recordMonitorFailure(error, operation: operation)
            do { try stopMonitor() } catch {
                log.error("Monitor cleanup failed: \(String(describing: error), privacy: .public)")
            }
            let reason: MonitorUnavailableReason =
                (error as? EngineError) == .formatUnsupported ? .formatUnsupported : .startFailed
            monitorStatus = .unavailable(reason: reason, outputName: resolvedMonitorOutput?.name)
            logMonitorUnavailable()
        }
    }
    private func recordMonitorFailure(_ error: Error, operation: String) {
        guard let output = resolvedMonitorOutput else { return }
        let typed = (error as? EngineError) ?? .invalidArgument(String(describing: error))
        let op: String
        if case .halFailure(_, let name) = typed { op = name } else { op = operation }
        lastMonitorFailure = MonitorFailure(
            operation: op, error: typed, output: output, workingRate: source?.sampleRate ?? 0)
        log.error(
            "Monitor failure operation=\(op, privacy: .public) error=\(typed.description, privacy: .public) uid=\(output.uid, privacy: .public) name=\(output.name, privacy: .public) nominal_rate=\(output.sampleRate, privacy: .public) available_rates=\(String(describing: output.supportedRates), privacy: .public)"
        )
    }
    private func logMonitorUnavailable() {
        let output = resolvedMonitorOutput
        log.notice(
            "Monitor resolved \(String(describing: self.monitorStatus), privacy: .public) output_uid=\(output?.uid ?? "none", privacy: .public) nominal_rate=\(output?.sampleRate ?? 0, privacy: .public) available_rates=\(String(describing: output?.supportedRates ?? []), privacy: .public)"
        )
    }
    private func stopMonitor() throws {
        monitorPending?.cancel()
        monitorTimer?.cancel()
        monitorTimer = nil
        for token in monitorTokens { try hardware.removeListener(token) }
        monitorTokens.removeAll()
        if let context = monitorContext {
            mb_monitor_fade_out(context)
            Thread.sleep(forTimeInterval: 0.012)
        }
        if let engine { mb_engine_set_monitor_enabled(engine, false) }
        try monitorSession?.stop()
        monitorSession = nil
        if let context = monitorContext { mb_monitor_destroy(context) }
        monitorContext = nil
        monitorOutput = nil
        monitorStatus = .off
        monitorCorrection = 0
    }
    private func monitorChanged(force: Bool = false) {
        if force && Date() < monitorSettleUntil { return }
        guard monitorEnabled, state == .running else { return }
        monitorPending?.cancel()
        monitorPending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.reconcileMonitor(force: force)
        }
    }
    private func reconcileMonitor(force: Bool = false) async {
        guard monitorEnabled, state == .running else { return }
        let devices = (try? hardware.devices()) ?? []
        let output = currentMonitorOutput(in: devices)
        guard
            force || !sameMonitorDescriptor(resolvedMonitorOutput, output)
                || resolvedMonitorEligible != monitorEligible(output, in: devices)
        else { return }
        do { try stopMonitor() } catch {
            recordMonitorFailure(error, operation: "Stop monitor")
            return
        }
        await startMonitor()
    }
    private func monitorTick() {
        guard let context = monitorContext, let session = monitorSession else { return }
        var stats = mb_monitor_stats()
        mb_monitor_read(context, &stats)
        monitorWindowMin = min(monitorWindowMin, stats.fill_min)
        monitorWindowMax = max(monitorWindowMax, stats.fill_max)
        monitorWindowPull = max(monitorWindowPull, stats.max_pull)
        if Date().timeIntervalSince(monitorMetricsDate) >= 1 {
            session.refreshMetrics()
            monitorSecondMin = monitorWindowMin
            monitorSecondMax = monitorWindowMax
            monitorSecondPull = monitorWindowPull
            monitorWindowMin = UInt32.max
            monitorWindowMax = 0
            monitorWindowPull = 0
            monitorMetricsDate = Date()
        }
        guard stats.pulling else { return }
        mb_monitor_pi_observe_clock(&monitorPI, &stats, source?.sampleRate ?? 48000, 0.05)
        monitorCorrection = mb_monitor_pi_update(
            &monitorPI, Double(stats.fill_min) - Double(stats.target), source?.sampleRate ?? 48000, 0.05,
            Double(stats.quantum))
        do {
            try session.setCorrection(monitorCorrection)
            mb_monitor_set_correction(context, monitorCorrection)
        } catch {
            recordMonitorFailure(error, operation: "Monitor drift control")
            try? stopMonitor()
            monitorStatus = .unavailable(reason: .startFailed, outputName: resolvedMonitorOutput?.name)
            logMonitorUnavailable()
        }
    }
    private func overloaded() { overloads += 1 }
    public func setChannelSelection(_ selection: ChannelSelection) {
        channelSelection = selection
        guard let engine else { return }
        switch selection {
        case .auto: mb_engine_set_channel_mode(engine, MB_AUTO, 0)
        case .monoMix: mb_engine_set_channel_mode(engine, MB_MONO_MIX, 0)
        case .mono(let channel): mb_engine_set_channel_mode(engine, MB_MONO, UInt32(clamping: channel - 1))
        case .stereo(let first): mb_engine_set_channel_mode(engine, MB_STEREO, UInt32(clamping: first - 1))
        }
    }
    private func applyControls() {
        guard let engine else { return }
        mb_engine_set_gain_db(engine, Float(controls.gainDB))
        mb_engine_set_muted(engine, controls.muted)
        mb_engine_set_eq_enabled(engine, controls.eq.enabled)
        mb_engine_set_band(engine, MB_LOW, Float(controls.eq.low.frequency), Float(controls.eq.low.gainDB), 0.9)
        mb_engine_set_band(
            engine, MB_MID, Float(controls.eq.mid.frequency), Float(controls.eq.mid.gainDB), Float(controls.eq.mid.q))
        mb_engine_set_band(engine, MB_HIGH, Float(controls.eq.high.frequency), Float(controls.eq.high.gainDB), 0.9)
    }
    private func updateControls(_ change: @Sendable (inout Settings) -> Void) async {
        controls = await settings.update { value in
            change(&value)
            value = value.sanitized()
        }
        applyControls()
    }
    public func setGain(db: Double) async {
        await updateControls { $0.gainDB = db.isFinite ? db : 0 }
    }
    public func setMuted(_ muted: Bool) async {
        await updateControls { $0.muted = muted }
    }
    public func setEQEnabled(_ enabled: Bool) async {
        await updateControls { $0.eq.enabled = enabled }
    }
    public func setBand(_ band: EQBand, frequency: Double, gainDB: Double, q: Double = 0.9) async {
        guard frequency.isFinite, gainDB.isFinite, q.isFinite else { return }
        await updateControls {
            switch band {
            case .low: $0.eq.low = EQShelfBand(frequency: frequency, gainDB: gainDB)
            case .mid: $0.eq.mid = EQPeakingBand(frequency: frequency, gainDB: gainDB, q: q)
            case .high: $0.eq.high = EQShelfBand(frequency: frequency, gainDB: gainDB)
            }
        }
    }
    public func applyVoicePreset() async {
        await updateControls {
            let enabled = $0.eq.enabled
            $0.eq = EQSettings()
            $0.eq.enabled = enabled
        }
    }
    public func resetEQ() async {
        await updateControls {
            let enabled = $0.eq.enabled
            $0.eq = EQSettings()
            $0.eq.low.gainDB = 0
            $0.eq.mid.gainDB = 0
            $0.eq.high.gainDB = 0
            $0.eq.enabled = enabled
        }
    }
    public func setChannelSelection(_ selection: ChannelSelection, forUID uid: String) async {
        guard selection.isValid else { return }
        await settings.update { $0.channelSelectionByUID[uid] = selection }
        if selected == uid { setChannelSelection(selection) }
    }
    public func meters() -> MetersSnapshot {
        var value = mb_meters()
        if let engine { mb_engine_read_meters(engine, &value) }
        return MetersSnapshot(
            inputPeak: value.input_peak, outputPeak: value.output_peak,
            gainReductionDB: value.gr_max_db, inputClipped: value.input_clipped)
    }
    private func changed(force: Bool = false, reason: RecoveryReason = .formatChanged) {
        forceRebuild = forceRebuild || force
        pendingReason = reason
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.recover()
        }
    }
    private static func isBluetooth(_ device: AudioDevice) -> Bool {
        device.transport == kAudioDeviceTransportTypeBluetooth
            || device.transport == kAudioDeviceTransportTypeBluetoothLE
    }
    /// Retired generations include format events queued by our own stop/profile release.
    private func formatEvent(uid: String, generation: UInt64) {
        guard generation == formatGeneration else { return }
        if Date() < settleUntil {
            if let source, Self.isBluetooth(source), source.uid == uid,
                let current = try? hardware.devices().first(where: { $0.uid == uid }),
                current.sampleRate != source.sampleRate
            {
                changed(force: true)
            }
            return
        }
        changed(force: true)
    }
    private func rateChanged(uid: String, generation: UInt64) async {
        guard generation == formatGeneration else { return }
        if let applied = appliedRates[uid], (try? hardware.devices().first { $0.uid == uid }?.sampleRate) == applied {
            return
        }
        formatEvent(uid: uid, generation: generation)
    }
    private func recover() async {
        // Start owns its asynchronous aggregate wait; never interleave a second build.
        guard state != .starting, let uid = selected, !sleeping else { return }
        let forced = forceRebuild
        let event = pendingReason
        forceRebuild = false
        pendingReason = .formatChanged
        let devices = (try? hardware.devices()) ?? []
        let currentSource = devices.first { $0.uid == uid && $0.alive }
        guard let currentDestination = devices.first(where: { $0.isBlackHole2ch && $0.alive }) else {
            if state != .error(.blackHoleMissing) {
                try? tearDown()
                setState(.error(.blackHoleMissing))
            }
            return
        }
        if hasRun, currentSource == nil {
            if state != .recovering(.sourceLost) {
                try? tearDown()
                setState(.recovering(.sourceLost))
            }
            return
        }
        if let current = currentSource, let previous = source, Self.isBluetooth(previous),
            Date() < settleUntil, previous.id == current.id, previous.alive == current.alive,
            previous.sampleRate == current.sampleRate
        {
            // HFP republishes stream/channel descriptors after the rate has settled.
            source = current
        }
        let sameSource = currentSource.map { current in source?.matchesEngineDescriptor(current) ?? false } ?? false
        let sameDestination = destination?.matchesEngineDescriptor(currentDestination) ?? false
        if state == .running, sameSource, sameDestination {
            await reconcileMonitor()
            // Right after a build the HAL still reports the engine's own start; a forced
            // notification then is not an external format change.
            let settling = Date() < settleUntil
            if !forced || (settling && event != .serviceRestarted) { return }
        }
        if event == .serviceRestarted {
            setState(.recovering(.serviceRestarted))
        } else if currentSource == nil {
            setState(.recovering(.sourceLost))
        } else {
            setState(.recovering(.formatChanged))
        }
        do {
            let profile = currentSource.flatMap { Self.isBluetooth($0) ? $0 : nil }
            try tearDown()
            try await build(bluetoothProfile: profile)
        } catch { setState(.error((error as? EngineError) ?? .invalidArgument(String(describing: error)))) }
    }
    private func currentMonitorOutput(in devices: [AudioDevice]) -> AudioDevice? {
        let id = try? hardware.defaultOutput()
        return devices.first {
            (monitorOutputUID == nil ? $0.id == id : $0.uid == monitorOutputUID) && $0.alive
        }
    }
    private func monitorEligible(_ output: AudioDevice?, in devices: [AudioDevice]) -> Bool {
        guard var output, output.outputChannels > 0 else { return false }
        output.inputChannels = 1
        return output.isEligible(in: devices)
    }
    private func sameMonitorDescriptor(_ previous: AudioDevice?, _ current: AudioDevice?) -> Bool {
        guard let previous, let current else { return previous == nil && current == nil }
        return previous.matchesEngineDescriptor(current)
            && previous.availableSampleRates == current.availableSampleRates
            && previous.subdeviceUIDs == current.subdeviceUIDs
    }
    private func recordRate(uid: String, current: Double, target: Double) {
        if previousRates[uid] == nil { previousRates[uid] = current }
        appliedRates[uid] = target
    }
    /// Restore device rates only on voluntary stop or source switch.
    private func restoreRates() {
        guard !appliedRates.isEmpty else { return }
        let devices = (try? hardware.devices()) ?? []
        for (uid, applied) in appliedRates {
            guard let device = devices.first(where: { $0.uid == uid && $0.alive }),
                let previous = previousRates[uid], previous != applied, device.sampleRate == applied
            else { continue }
            try? hardware.setRate(device.id, rate: previous)
        }
        appliedRates.removeAll()
        previousRates.removeAll()
    }
    private func tearDown() throws {
        formatGeneration &+= 1
        do { try stopMonitor() } catch {
            // A failed output cleanup retains its context/ring; the bridge can still stop.
            recordMonitorFailure(error, operation: "Stop monitor during engine teardown")
            monitorStatus = .unavailable(reason: .startFailed, outputName: resolvedMonitorOutput?.name)
            logMonitorUnavailable()
        }
        for token in tokens { try hardware.removeListener(token) }
        tokens.removeAll()

        let aggregateExists: Bool
        if let aggregate {
            aggregateExists = try hardware.devices().contains { $0.id == aggregate && $0.uid == AggregateBuilder.uid }
        } else {
            aggregateExists = false
        }
        if let id = aggregate, let proc {
            if aggregateExists {
                if let engine { mb_engine_begin_fade_out(engine) }
                Thread.sleep(forTimeInterval: 0.04)
                try hardware.stopIO(id, proc: proc)
                try hardware.destroyIO(id, proc: proc)
            }
            // An absent aggregate has no registered IOProc after a HAL restart.
            self.proc = nil
        }
        if let engine {
            var counters = mb_counters()
            mb_engine_read_counters(engine, &counters)
            completedCounters.cycles += counters.cycles
            completedCounters.input_missing += counters.input_missing
            completedCounters.nonfinite_resets += counters.nonfinite_resets
            completedCounters.frames_over_max += counters.frames_over_max
            completedCounters.io_delta_host = counters.io_delta_host
            mb_engine_destroy(engine)
            self.engine = nil
        }
        if let aggregate {
            if aggregateExists { try hardware.destroyAggregate(aggregate) }
            self.aggregate = nil
        }
    }
    public func willSleep() throws {
        guard selected != nil else { return }
        sleeping = true
        pending?.cancel()
        try tearDown()
        setState(.recovering(.sleep))
    }
    public func didWake() {
        sleeping = false
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: self?.wakeDelay ?? .seconds(1)) } catch { return }
            await self?.wakeUp()
        }
    }
    /// One start attempt after the wake; a HAL/format failure falls back to `recovering`.
    private func wakeUp() async {
        guard selected != nil, !sleeping else { return }
        do {
            try tearDown()
            try await build()
        } catch {
            setState(.recovering(.wakeFailed))
        }
    }
    public func stop() async throws {
        selected = nil
        sleeping = false
        pending?.cancel()
        try tearDown()
        restoreRates()
        for token in systemTokens { try hardware.removeListener(token) }
        systemTokens.removeAll()
        if let defaultToken {
            try hardware.removeListener(defaultToken)
            self.defaultToken = nil
        }
        setState(.stopped)
        try await routingManager.engineWillStop()
        await settings.flush()
    }
    private func defaultChanged() async throws {
        try await routingManager.defaultInputDidChange()
    }
    public func setDefaultInputManagement(_ enabled: Bool) async { await routingManager.setManagementEnabled(enabled) }
    public func useBlackHole() async throws { try await routingManager.useBlackHole() }
    public func availableDevices() throws -> [AudioDevice] { try hardware.devices() }
    public func status() -> EngineStatus {
        var counters = mb_counters()
        if let engine { mb_engine_read_counters(engine, &counters) }
        counters.cycles += completedCounters.cycles
        counters.input_missing += completedCounters.input_missing
        counters.nonfinite_resets += completedCounters.nonfinite_resets
        counters.frames_over_max += completedCounters.frames_over_max
        let rate = source?.sampleRate ?? 0
        let latency = Double(reportedFrames)
        let devices = (try? hardware.devices()) ?? []
        let currentID = try? hardware.defaultInput()
        let current = devices.first { $0.id == currentID }
        let defaultStatus: DefaultInputStatus
        if currentID != nil, current != nil {
            let isBlackHole = current?.uid == destination?.uid || currentID == destination?.id
            defaultStatus = DefaultInputStatus(
                isBlackHole: isBlackHole, divergedByUser: state == .running && !isBlackHole)
        } else {
            defaultStatus = .unresolved
        }
        var result = EngineStatus(
            state: state, source: source, blackHole: destination, defaultInput: defaultStatus,
            defaultInputName: current?.name,
            sampleRate: rate,
            bufferFrames: buffer, reportedLatencyMs: rate > 0 ? latency * 1000 / rate : 0,
            overloads: overloads, cycles: counters.cycles, inputMissing: counters.input_missing,
            nonfiniteResets: counters.nonfinite_resets, ioDeltaHost: counters.io_delta_host)
        if let monitorContext {
            mb_monitor_peek(monitorContext, &result.monitorStats)
            result.monitorStats.correction = monitorCorrection
            result.monitorStats.fill_min = monitorSecondMin
            result.monitorStats.fill_max = monitorSecondMax
            result.monitorStats.max_pull = monitorSecondPull
            result.monitorHostLatencyMs =
                result.monitorStats.latency_host > 0 ? Self.hostMilliseconds(result.monitorStats.latency_host) : nil
            if let session = monitorSession, let output = monitorOutput {
                result.monitorBufferRequestResult = session.bufferRequestResult
                result.monitorOutputBufferFrames = session.outputBufferFrames
                result.monitorOutputBufferReadFromAUHAL = session.outputBufferReadFromAUHAL
                result.monitorPreferredBufferFrames = MonitorLatency.preferredBufferFrames(
                    engineFrames: buffer,
                    engineRate: rate, outputRate: output.sampleRate, range: output.bufferRange)
                result.monitorVarispeedLatencyMs = session.varispeedLatencySeconds * 1000
                result.monitorAUHALLatencyMs = session.auhalLatencySeconds * 1000
            }
        }
        result.monitorOutput = resolvedMonitorOutput
        result.lastMonitorFailure = lastMonitorFailure
        result.monitor = state == .running ? monitorSnapshot() : .off
        return result
    }
}
