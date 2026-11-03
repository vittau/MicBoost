import CoreAudio
import Dispatch
import Foundation
import MicBoostDSP

public enum EngineState: Sendable, Equatable {
    case stopped, starting, running
    case recovering(String)
    case error(EngineError)
}
public struct EngineStatus: Sendable {
    public var state: EngineState
    public var source: AudioDevice?
    public var blackHole: AudioDevice?
    public var defaultInput: DefaultInputStatus
    public var sampleRate: Double
    public var bufferFrames: UInt32
    public var reportedLatencyMs: Double
    public var overloads: UInt64
    public var cycles: UInt64
    public var inputMissing: UInt64
    public var nonfiniteResets: UInt64
    public var ioDeltaHost: UInt64
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
    private let settings: SettingsStore
    private var controls = Settings()
    private var channelSelection: ChannelSelection = .auto
    private var forceRebuild = false
    private let hardware: any EngineHardware
    private var state: EngineState = .stopped
    private var hasRun = false
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
    private var pending: Task<Void, Never>?
    public init(settings: SettingsStore = SettingsStore(storage: UserDefaultsStorage())) {
        hardware = CoreAudioHardware()
        self.settings = settings
    }
    public init(
        hardware: sending any EngineHardware, settings: SettingsStore = SettingsStore(storage: UserDefaultsStorage())
    ) {
        self.hardware = hardware
        self.settings = settings
    }
    public func start(inputUID: String, bufferFrames: UInt32? = nil) async throws {
        let stored = await settings.current
        controls = stored
        let bufferFrames = bufferFrames ?? UInt32(stored.bufferFrames)
        channelSelection = stored.channelSelectionByUID[inputUID] ?? .auto
        guard bufferFrames > 0 else { throw EngineError.invalidArgument("Buffer must be positive") }
        try tearDown()
        hasRun = false
        selected = inputUID
        requested = bufferFrames
        if tokens.isEmpty {
            tokens.append(
                try hardware.addListener(
                    .init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
                    queue: queue
                ) { [weak self] in Task { await self?.changed() } })
        }
        try build()
    }
    private func build() throws {
        state = .starting
        do {
            guard hardware.microphoneAuthorized else {
                throw EngineError.microphonePermissionDenied
            }
            let devices = try hardware.devices()
            guard let blackHole = devices.first(where: { $0.isBlackHole2ch && $0.alive }) else {
                state = .error(.blackHoleMissing)
                return
            }
            destination = blackHole
            guard let source = devices.first(where: { $0.uid == selected && $0.alive && $0.isEligible(in: devices) })
            else {
                state = hasRun ? .recovering("sourceLost") : .error(.sourceUnavailable(selected ?? ""))
                return
            }
            self.source = source
            if source.sampleRate != blackHole.sampleRate {
                guard
                    blackHole.availableSampleRates.contains(where: {
                        $0.minimum <= source.sampleRate && $0.maximum >= source.sampleRate
                    })
                else {
                    throw EngineError.formatUnsupported
                }
                try hardware.setRate(blackHole.id, rate: source.sampleRate)
            }
            for stale in devices where stale.uid == AggregateBuilder.uid {
                try hardware.destroyAggregate(stale.id)
            }
            let id = try hardware.createAggregate(source: source.uid, destination: blackHole.uid)
            aggregate = id
            let deadline = Date().addingTimeInterval(2)
            while !(try hardware.devices().contains(where: { $0.id == id && $0.alive })) {
                guard Date() < deadline else { throw EngineError.halFailure(-1, "Wait for aggregate") }
                Thread.sleep(forTimeInterval: 0.01)
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
            for device in [source, blackHole] {
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
                    tokens.append(
                        try hardware.addListener(.init(device.id, selector), queue: queue) { [weak self] in
                            Task { await self?.changed(force: true) }
                        })
                }
            }
            for device in [source, blackHole] {
                for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                    tokens.append(
                        try hardware.addListener(
                            .init(device.id, kAudioDevicePropertyStreamConfiguration, scope), queue: queue
                        ) { [weak self] in
                            Task { await self?.changed(force: true) }
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
            state = .running
        } catch {
            state = .error((error as? EngineError) ?? .invalidArgument(String(describing: error)))
            try tearDown()
            throw error
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
    public func resetEQ() async {
        await updateControls {
            let enabled = $0.eq.enabled
            $0.eq = EQSettings()
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
    private func changed(force: Bool = false) {
        forceRebuild = forceRebuild || force
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.recover()
        }
    }
    private func recover() {
        guard selected != nil else { return }
        let forced = forceRebuild
        forceRebuild = false
        if !forced, state == .running, let devices = try? hardware.devices(),
            let currentSource = devices.first(where: { $0.uid == selected }),
            let currentDestination = devices.first(where: { $0.isBlackHole2ch }),
            currentSource == source, currentDestination == destination
        {
            return
        }
        state = .recovering("formatChanged")
        do {
            try tearDown()
            try build()
        } catch { state = .error((error as? EngineError) ?? .invalidArgument(String(describing: error))) }
    }
    private func tearDown() throws {
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
        for token in tokens.dropFirst() { try hardware.removeListener(token) }
        if tokens.count > 1 { tokens.removeSubrange(1...) }
    }
    public func willSleep() throws {
        try tearDown()
        state = .recovering("sleep")
    }
    public func didWake() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.recover()
        }
    }
    public func stop() throws {
        selected = nil
        pending?.cancel()
        try tearDown()
        for token in tokens { try hardware.removeListener(token) }
        tokens.removeAll()
        state = .stopped
    }
    public func status() -> EngineStatus {
        var counters = mb_counters()
        if let engine { mb_engine_read_counters(engine, &counters) }
        counters.cycles += completedCounters.cycles
        counters.input_missing += completedCounters.input_missing
        counters.nonfinite_resets += completedCounters.nonfinite_resets
        counters.frames_over_max += completedCounters.frames_over_max
        let rate = source?.sampleRate ?? 0
        let latency = Double(reportedFrames)
        let defaultStatus: DefaultInputStatus
        if let current = try? hardware.defaultInput() {
            defaultStatus = DefaultInputStatus(isBlackHole: current == destination?.id)
        } else {
            defaultStatus = .unresolved
        }
        return EngineStatus(
            state: state, source: source, blackHole: destination, defaultInput: defaultStatus, sampleRate: rate,
            bufferFrames: buffer, reportedLatencyMs: rate > 0 ? latency * 1000 / rate : 0,
            overloads: overloads, cycles: counters.cycles, inputMissing: counters.input_missing,
            nonfiniteResets: counters.nonfinite_resets, ioDeltaHost: counters.io_delta_host)
    }
}
