import AVFoundation
import CoreAudio
import Foundation
import MicBoostCore

let usage = "Usage: micboost-diag devices [--json] | capture --device <uid> --seconds N --out file.wav"
do {
    let args = Array(CommandLine.arguments.dropFirst())
    let hardware = CoreAudioHardware()
    guard let command = args.first else { throw EngineError.invalidArgument(usage) }
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
                print("  Alive: \(device.alive), eligible source: \(device.isEligible(in: snapshot.devices))")
            }
        }
    case "latency", "soak":
        var options: [String: String] = [:]
        guard args.count % 2 == 1 else { throw EngineError.invalidArgument(usage) }
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--input", "--buffer", "--trials", "--minutes"].contains(args[i]), options[args[i]] == nil else {
                throw EngineError.invalidArgument(usage)
            }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--input"], let buffer = UInt32(options["--buffer"] ?? "256"), buffer > 0,
            let trials = Int(options["--trials"] ?? "10"), trials > 0, trials <= 100,
            let minutes = Int(options["--minutes"] ?? "60"), minutes > 0, minutes <= 1440
        else {
            throw EngineError.invalidArgument(usage)
        }
        let controller = EngineController()
        do {
            try await controller.start(inputUID: uid, bufferFrames: buffer)
            try await Task.sleep(for: .seconds(1))
            var values: [Double] = []
            let iterations = command == "soak" ? minutes : trials
            let begin = Date()
            for iteration in 0..<iterations {
                let status = await controller.status()
                guard let source = status.source, let destination = status.blackHole else {
                    throw EngineError.invalidArgument("Engine not running")
                }
                let result = try hardware.measureLatency(source: source, destination: destination)
                values.append(result.milliseconds)
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print(
                    "trial=\(iteration + 1) latency_ms=\(result.milliseconds) correlation=\(result.correlation) source_peak=\(result.sourcePeak) BlackHole_peak=\(result.destinationPeak) HAL_ms=\(status.reportedLatencyMs) io_delta_host=\(status.ioDeltaHost) overloads=\(status.overloads) input_missing=\(status.inputMissing) nonfinite_resets=\(status.nonfiniteResets) maxrss=\(usage.ru_maxrss) cpu_user_s=\(usage.ru_utime.tv_sec)"
                )

                if command == "soak" {
                    let remaining = begin.addingTimeInterval(Double(iteration + 1) * 60).timeIntervalSinceNow
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                }
            }
            values.sort()
            print("latency_ms median=\(values[values.count / 2]) min=\(values.first ?? 0) max=\(values.last ?? 0)")
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
        let controller = EngineController()
        do {
            try await controller.start(inputUID: uid, bufferFrames: buffer)
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                let status = await controller.status()
                print(
                    "state=\(status.state) rate=\(status.sampleRate) buffer=\(status.bufferFrames) HAL_ms=\(status.reportedLatencyMs) cycles=\(status.cycles) overloads=\(status.overloads) input_missing=\(status.inputMissing) nonfinite_resets=\(status.nonfiniteResets) io_delta_host=\(status.ioDeltaHost)"
                )
                try await Task.sleep(for: .seconds(min(1, max(0, deadline.timeIntervalSinceNow))))
            } while Date() < deadline
            try await controller.stop()
        } catch {
            try await controller.stop()
            throw error
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
