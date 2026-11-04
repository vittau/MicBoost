import AVFoundation
import CoreAudio
import Foundation
import MicBoostCore

let usage =
    "Usage: micboost-diag devices [--json] | permission | set-rate --device UID --rate HZ | capture --device UID --seconds N --out file.wav | run --input UID [--buffer N] [--seconds N] | latency --input UID [--trials N] [--buffer N] | monitor-latency --input UID [--output UID] [--seconds N] [--buffer N] | soak --input UID [--minutes N] [--buffer N]; effects: --monitor --monitor-silent --gain-db N --mute --eq-low F:G --eq-mid F:G:Q --eq-high F:G --eq-off"
do {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    var args: [String] = []
    var effects: [String: String] = [:]
    var index = 0
    while index < rawArgs.count {
        let key = rawArgs[index]
        if ["--gain-db", "--eq-low", "--eq-mid", "--eq-high", "--mute", "--eq-off", "--monitor", "--monitor-silent"]
            .contains(key)
        {
            guard effects[key] == nil else { throw EngineError.invalidArgument(usage) }
            if key == "--mute" || key == "--eq-off" || key == "--monitor" || key == "--monitor-silent" {
                effects[key] = "true"
            } else {
                index += 1
                guard index < rawArgs.count else { throw EngineError.invalidArgument(usage) }
                effects[key] = rawArgs[index]
            }
        } else {
            args.append(key)
        }
        index += 1
    }
    let hardware = CoreAudioHardware()
    guard let command = args.first else { throw EngineError.invalidArgument(usage) }
    guard effects.isEmpty || ["run", "latency", "soak", "monitor-latency"].contains(command) else {
        throw EngineError.invalidArgument(usage)
    }
    guard effects["--monitor"] == nil || effects["--monitor-silent"] != nil else {
        throw EngineError.invalidArgument("--monitor requires --monitor-silent; diagnostics never play monitor audio")
    }
    switch command {
    case "permission":
        print("microphoneAuthorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    case "devices":
        guard args.count == 1 || args == ["devices", "--json"] else { throw EngineError.invalidArgument(usage) }
        let service = DeviceService(hardware: hardware, queue: DispatchQueue(label: "diag.devices")) { _ in }
        let snapshot = try service.snapshot()
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } else {
            print(
                "Default input: \(snapshot.defaultInputUID ?? "none")\nBlackHole 2ch: \(snapshot.blackHole?.uid ?? "absent")"
            )
            print(
                "Default output: \(snapshot.devices.first { $0.id == (try? hardware.defaultOutput()) }?.uid ?? "none")")
            for device in snapshot.devices {
                print("\n\(device.name)")
                print("  UID: \(device.uid)")
                print("  Manufacturer: \(device.manufacturer)")
                print("  Transport: \(transportName(device.transport))")
                print("  Channels: \(device.inputChannels) input, \(device.outputChannels) output")
                print("  Nominal rate: \(number(device.sampleRate)) Hz")
                let rates = device.availableSampleRates.map { range in
                    range.minimum == range.maximum
                        ? number(range.minimum)
                        : "\(number(range.minimum))...\(number(range.maximum))"
                }.joined(separator: ", ")
                print("  Available rates: \(rates) Hz")
                print("  Buffer: \(number(device.bufferRange.minimum))...\(number(device.bufferRange.maximum)) frames")
                print("  Input latency: \(frameDuration(device.inputLatency, rate: device.sampleRate))")
                print("  Output latency: \(frameDuration(device.outputLatency, rate: device.sampleRate))")
                print("  Input safety offset: \(frameDuration(device.inputSafetyOffset, rate: device.sampleRate))")
                print("  Output safety offset: \(frameDuration(device.outputSafetyOffset, rate: device.sampleRate))")
                if device.transport == kAudioDeviceTransportTypeBuiltIn || device.isBlackHole2ch {
                    let input = try hardware.latencyComponents(device.id, scope: kAudioObjectPropertyScopeInput)
                    let output = try hardware.latencyComponents(device.id, scope: kAudioObjectPropertyScopeOutput)
                    print(
                        "  HAL input components: device=\(input.device) safety=\(input.safety) stream=\(input.stream)")
                    print(
                        "  HAL output components: device=\(output.device) safety=\(output.safety) stream=\(output.stream)"
                    )
                }
                print("  Alive: \(device.alive), eligible source: \(device.isEligible(in: snapshot.devices))")
            }
        }
    case "monitor-latency":
        var options: [String: String] = [:]
        guard args.count % 2 == 1 else { throw EngineError.invalidArgument(usage) }
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--input", "--output", "--buffer", "--seconds"].contains(args[i]), options[args[i]] == nil else {
                throw EngineError.invalidArgument(usage)
            }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--input"], let seconds = Int(options["--seconds"] ?? "10"), seconds > 0,
            seconds <= 3600,
            let buffer = UInt32(options["--buffer"] ?? "256"), buffer > 0
        else { throw EngineError.invalidArgument(usage) }
        let controller = try await diagnosticController(effects: [:])
        await controller.setDiagnosticMonitorSilent(true)
        await controller.setMonitorOutput(uid: options["--output"])
        try await controller.setMonitorEnabled(true)
        do {
            try await controller.start(inputUID: uid, bufferFrames: buffer)
            var values: [Double] = []
            for second in 1...seconds {
                try await Task.sleep(for: .seconds(1))
                let status = await controller.status()
                guard case .active(let output, let added, let total) = status.monitor, let source = status.source else {
                    throw EngineError.invalidArgument("Monitor unavailable: \(status.monitor)")
                }
                if let added { values.append(added) }
                let input = try hardware.latencyComponents(source.id, scope: kAudioObjectPropertyScopeInput)
                let out = try hardware.latencyComponents(output.id, scope: kAudioObjectPropertyScopeOutput)
                let stats = status.monitorStats
                report(
                    "second=\(second) monitor_added_ms=\(added.map(String.init(describing:)) ?? "pending") total_estimate_ms=\(total) fill=\(stats.fill) target=\(stats.target) correction_ppm=\(stats.correction * 1e6) underruns=\(stats.underruns) overruns=\(stats.overruns) input_device_frames=\(input.device) input_safety_frames=\(input.safety) input_stream_frames=\(input.stream) output_device_frames=\(out.device) output_safety_frames=\(out.safety) output_stream_frames=\(out.stream)"
                )
            }
            guard !values.isEmpty else { throw EngineError.invalidArgument("No monitor host timestamps") }
            values.sort()
            let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
            report("monitor_added_ms median=\(median) min=\(values.first ?? 0) max=\(values.last ?? 0)")
            try await controller.stop()
        } catch {
            try await controller.stop()
            throw error
        }
    case "latency", "soak":
        var options: [String: String] = [:]
        guard args.count % 2 == 1 else { throw EngineError.invalidArgument(usage) }
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--input", "--buffer", "--trials", "--minutes", "--output"].contains(args[i]),
                options[args[i]] == nil
            else {
                throw EngineError.invalidArgument(usage)
            }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--input"], let buffer = UInt32(options["--buffer"] ?? "256"), buffer > 0,
            let trials = Int(options["--trials"] ?? "10"), trials > 0, trials <= 100,
            let minutes = Int(options["--minutes"] ?? "20"), minutes > 0, minutes <= 1440
        else {
            throw EngineError.invalidArgument(usage)
        }
        let controller = try await diagnosticController(effects: effects)
        do {
            try await controller.start(inputUID: uid, bufferFrames: buffer)
            try await Task.sleep(for: .seconds(1))
            var values: [Double] = []
            var measuredRate: Double = 0
            let iterations = command == "soak" ? minutes : trials
            let begin = Date()
            for iteration in 0..<iterations {
                let status = await controller.status()
                guard let source = status.source, let destination = status.blackHole else {
                    throw EngineError.invalidArgument("Engine not running")
                }
                let result = try hardware.measureLatency(source: source, destination: destination)
                let measured = result.milliseconds
                values.append(measured)
                measuredRate = source.sampleRate
                let usage = try processUsage()
                report(
                    "trial=\(iteration + 1) latency_ms=\(measured) latency_frames=\(measured * source.sampleRate / 1000) correlation=\(result.correlation) source_peak=\(result.sourcePeak) BlackHole_peak=\(result.destinationPeak) monitor=\(status.monitor) HAL_ms=\(status.reportedLatencyMs) io_delta_host=\(status.ioDeltaHost) io_delta_ms=\(hostMilliseconds(status.ioDeltaHost)) overloads=\(status.overloads) input_missing=\(status.inputMissing) nonfinite_resets=\(status.nonfiniteResets) rss_bytes=\(usage.resident) maxrss_bytes=\(usage.peakResident) cpu_seconds=\(usage.cpuSeconds)"
                )

                if command == "soak" {
                    let remaining = begin.addingTimeInterval(Double(iteration + 1) * 60).timeIntervalSinceNow
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                }
            }
            values.sort()
            let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
            report(
                "latency_ms median=\(median) min=\(values.first ?? 0) max=\(values.last ?? 0) median_frames=\(median * measuredRate / 1000)"
            )
            try await controller.stop()
        } catch {
            try await controller.stop()
            throw error
        }
    case "run":
        var options: [String: String] = [:]
        guard args.count % 2 == 1 else { throw EngineError.invalidArgument(usage) }
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--input", "--buffer", "--seconds"].contains(args[i]), options[args[i]] == nil else {
                throw EngineError.invalidArgument(usage)
            }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--input"], let seconds = Double(options["--seconds"] ?? "30"),
            seconds.isFinite, seconds > 0, let buffer = UInt32(options["--buffer"] ?? "256"), buffer > 0
        else {
            throw EngineError.invalidArgument(usage)
        }
        let controller = try await diagnosticController(effects: effects)
        do {
            let startedAt = Date()
            await controller.observe { state in
                let elapsed = Date().timeIntervalSince(startedAt) * 1000
                report("event state=\(state) t_ms=\(String(format: "%.1f", elapsed))")
            }
            try await controller.start(inputUID: uid, bufferFrames: buffer)
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                let status = await controller.status()
                let meters = await controller.meters()
                report(
                    "input_peak=\(meters.inputPeak) output_peak=\(meters.outputPeak) gr_db=\(meters.gainReductionDB) cpu_seconds=\(try processUsage().cpuSeconds)"
                )
                report(
                    "state=\(status.state) rate=\(status.sampleRate) buffer=\(status.bufferFrames) monitor=\(status.monitor) HAL_ms=\(status.reportedLatencyMs) cycles=\(status.cycles) overloads=\(status.overloads) input_missing=\(status.inputMissing) nonfinite_resets=\(status.nonfiniteResets) io_delta_host=\(status.ioDeltaHost) io_delta_ms=\(hostMilliseconds(status.ioDeltaHost))"
                )
                try await Task.sleep(for: .seconds(min(1, max(0, deadline.timeIntervalSinceNow))))
            } while Date() < deadline
            try await controller.stop()
        } catch {
            try await controller.stop()
            throw error
        }
    case "set-rate":
        guard args.count == 5, args[1] == "--device", args[3] == "--rate" else {
            throw EngineError.invalidArgument(usage)
        }
        let uid = args[2]
        guard let requested = Double(args[4]), requested.isFinite, requested > 0 else {
            throw EngineError.invalidArgument("Invalid rate: \(args[4])\n" + usage)
        }
        guard let device = try hardware.devices().first(where: { $0.uid == uid }) else {
            throw EngineError.invalidArgument("Device not found: \(uid)")
        }
        guard device.supportedRates.contains(where: { $0.minimum <= requested && requested <= $0.maximum }) else {
            throw EngineError.invalidArgument("\(number(requested)) Hz is not available for \(uid)")
        }
        try hardware.setRate(device.id, rate: requested)
        // The HAL applies the new rate asynchronously; give it up to a second.
        let deadline = Date().addingTimeInterval(1)
        var actual = device.sampleRate
        repeat {
            actual = (try? hardware.devices().first(where: { $0.uid == uid })?.sampleRate) ?? actual
            if actual == requested { break }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        print("rate uid=\(uid) before=\(number(device.sampleRate)) after=\(number(actual))")
        guard actual == requested else {
            throw EngineError.invalidArgument("Device kept \(number(actual)) Hz instead of \(number(requested)) Hz")
        }
    case "capture":
        guard args.count == 7 else { throw EngineError.invalidArgument(usage) }
        var options: [String: String] = [:]
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--device", "--seconds", "--out"].contains(args[i]), options[args[i]] == nil else {
                throw EngineError.invalidArgument(usage)
            }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--device"], let duration = options["--seconds"], let seconds = Double(duration),
            let output = options["--out"], let device = try hardware.devices().first(where: { $0.uid == uid })
        else { throw EngineError.invalidArgument("Invalid options or device not found\n" + usage) }
        print(try hardware.capture(device: device, seconds: seconds, destination: URL(fileURLWithPath: output)))
    default: throw EngineError.invalidArgument(usage)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

func number(_ value: Double) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
}

func frameDuration(_ frames: UInt32, rate: Double) -> String {
    let milliseconds = rate > 0 ? String(format: "%.3f", Double(frames) * 1000 / rate) : "unknown"
    return "\(frames) frames (\(milliseconds) ms)"
}

func transportName(_ transport: UInt32) -> String {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
        return "continuity"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    case kAudioDeviceTransportTypePCI: return "pci"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    default:
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: transport >> $0) }
        let fourCC = bytes.map { byte in
            (32...126).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "\\x%02X", byte)
        }.joined()
        return "unknown(\(fourCC))"
    }
}

func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func processUsage() throws -> (resident: UInt64, peakResident: Int, cpuSeconds: Double) {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw EngineError.invalidArgument("getrusage failed") }
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), words, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw EngineError.invalidArgument("task_info failed: \(status)") }
    let cpu =
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    return (info.resident_size, usage.ru_maxrss, cpu)
}

func hostMilliseconds(_ ticks: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func diagnosticController(effects: [String: String]) async throws -> EngineController {
    guard let defaults = UserDefaults(suiteName: "io.github.vittau.MicBoost.diag") else {
        throw EngineError.invalidArgument("Diagnostic settings unavailable")
    }
    let store = SettingsStore(storage: UserDefaultsStorage(defaults: defaults))
    let controller = EngineController(settings: store)
    await controller.setDefaultInputManagement(false)
    await controller.setDiagnosticMonitorSilent(effects["--monitor-silent"] != nil)
    try await controller.setMonitorEnabled(effects["--monitor"] != nil)
    await controller.setGain(db: 0)
    await controller.setMuted(effects["--mute"] != nil)
    await controller.resetEQ()
    await controller.setEQEnabled(effects["--eq-off"] == nil)
    if let value = effects["--gain-db"] {
        guard let db = Double(value), db.isFinite else { throw EngineError.invalidArgument(usage) }
        await controller.setGain(db: db)
    }
    for (key, band) in [("--eq-low", EQBand.low), ("--eq-mid", .mid), ("--eq-high", .high)] {
        if let value = effects[key] {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            let values = fields.compactMap { Double($0) }
            guard values.count == fields.count, values.count == (key == "--eq-mid" ? 3 : 2),
                values.allSatisfy({ $0.isFinite })
            else {
                throw EngineError.invalidArgument(usage)
            }
            await controller.setBand(
                band, frequency: values[0], gainDB: values[1], q: values.count == 3 ? values[2] : 0.9)
        }
    }
    return controller
}
