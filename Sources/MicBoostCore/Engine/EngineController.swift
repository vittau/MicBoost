import AVFoundation
import CoreAudio
import Dispatch
import Foundation
import MicBoostDSP

public enum EngineState: Sendable, Equatable {
    case stopped, starting, running
    case recovering(String)
    case error(String)
}
public struct EngineStatus: Sendable {
    public var state: EngineState
    public var source: AudioDevice?
    public var blackHole: AudioDevice?
    public var sampleRate: Double
    public var bufferFrames: UInt32
    public var reportedLatencyMs: Double
    public var overloads: UInt64
    public var cycles: UInt64
    public var inputMissing: UInt64
    public var nonfiniteResets: UInt64
    public var ioDeltaHost: UInt64
}
public actor EngineController {
    private let queue = DispatchSerialQueue(label: "io.github.vittau.MicBoost.engine")
    nonisolated public var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let hardware: any EngineHardware
    private var state: EngineState = .stopped
    private var selected: String?
    private var requested: UInt32 = 256
    private var source: AudioDevice?
    private var destination: AudioDevice?
    private var aggregate: AudioObjectID?
    private var proc: AudioDeviceIOProcID?
    private var engine: OpaquePointer?
    private var buffer: UInt32 = 0
    private var overloads: UInt64 = 0
    private var tokens: [UUID] = []
    private var pending: Task<Void, Never>?
    public init() { hardware = CoreAudioHardware() }
    public init(hardware: sending any EngineHardware) { self.hardware = hardware }
    public func start(inputUID: String, bufferFrames: UInt32 = 256) throws {
        guard bufferFrames > 0 else { throw EngineError.invalidArgument("Buffer must be positive") }
        try tearDown()
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
            guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied,
                AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
            else {
                throw EngineError.invalidArgument("Microphone permission denied")
            }
            let devices = try hardware.devices()
            guard let blackHole = devices.first(where: { $0.isBlackHole2ch && $0.alive }) else {
                state = .error("blackHoleMissing")
                return
            }
            destination = blackHole
            guard let source = devices.first(where: { $0.uid == selected && $0.alive && $0.isEligible(in: devices) })
            else {
                state = .recovering("sourceLost")
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
            guard let context = mb_engine_create(buffer, source.sampleRate) else { throw EngineError.formatUnsupported }
            engine = context
            guard mb_engine_configure(context, &routing) == 0 else { throw EngineError.formatUnsupported }
            let io = try hardware.createIO(id, context: context)
            proc = io
            try hardware.streamUsage(
                id, proc: io, input: true,
                enabled: sourceLayout.inputs.map { _ in true } + destinationLayout.inputs.map { _ in false })
            try hardware.streamUsage(
                id, proc: io, input: false,
                enabled: sourceLayout.outputs.map { _ in false } + destinationLayout.outputs.map { _ in true })
            try hardware.startIO(id, proc: io)
            for device in [source, blackHole] {
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
                    tokens.append(
                        try hardware.addListener(.init(device.id, selector), queue: queue) { [weak self] in
                            Task { await self?.changed() }
                        })
                }
            }
            tokens.append(
                try hardware.addListener(.init(id, kAudioDeviceProcessorOverload), queue: queue) { [weak self] in
                    Task { await self?.overloaded() }
                })
            state = .running
        } catch {
            try tearDown()
            state = .error(String(describing: error))
            throw error
        }
    }
    private func overloaded() { overloads += 1 }
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.recover()
        }
    }
    private func recover() {
        guard selected != nil else { return }
        if state == .running, let devices = try? hardware.devices(),
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
        } catch { state = .error(String(describing: error)) }
    }
    private func tearDown() throws {
        if let id = aggregate, let proc {
            if let engine { mb_engine_begin_fade_out(engine) }
            Thread.sleep(forTimeInterval: 0.04)
            try hardware.stopIO(id, proc: proc)
            try hardware.destroyIO(id, proc: proc)
            self.proc = nil
        }
        if let engine {
            mb_engine_destroy(engine)
            self.engine = nil
        }
        if let aggregate {
            try hardware.destroyAggregate(aggregate)
            self.aggregate = nil
        }
        for token in tokens.dropFirst() { try hardware.removeListener(token) }
        if tokens.count > 1 { tokens.removeSubrange(1...) }
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
        let rate = source?.sampleRate ?? 0
        let latency = Double(
            (source?.inputLatency ?? 0) + (source?.inputSafetyOffset ?? 0)
                + buffer + (destination?.outputLatency ?? 0) + (destination?.outputSafetyOffset ?? 0))
        return EngineStatus(
            state: state, source: source, blackHole: destination, sampleRate: rate,
            bufferFrames: buffer, reportedLatencyMs: rate > 0 ? latency * 1000 / rate : 0,
            overloads: overloads, cycles: counters.cycles, inputMissing: counters.input_missing,
            nonfiniteResets: counters.nonfinite_resets, ioDeltaHost: counters.io_delta_host)
    }
}
