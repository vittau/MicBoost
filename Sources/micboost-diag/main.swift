import CoreAudio
import Foundation
import MicBoostCore

let usage = "Usage: micboost-diag devices [--json] | capture --device <uid> --seconds N --out file.wav"
do {
    let args = Array(CommandLine.arguments.dropFirst())
    let hardware = CoreAudioHardware()
    guard let command = args.first else { throw EngineError.invalidArgument(usage) }
    switch command {
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
