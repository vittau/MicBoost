import Foundation
import MicBoostCore
let usage = "Usage: micboost-diag devices [--json] | capture --device <uid> --seconds N --out file.wav"
do {
    let args = Array(CommandLine.arguments.dropFirst()); let hardware = CoreAudioHardware()
    guard let command = args.first else { throw EngineError.invalidArgument(usage) }
    switch command {
    case "devices":
        guard args.count == 1 || args == ["devices", "--json"] else { throw EngineError.invalidArgument(usage) }
        let service = DeviceService(hardware: hardware, queue: DispatchQueue(label: "diag.devices")) { _ in }
        let snapshot = try service.snapshot()
        if args.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } else {
            print("Default input: \(snapshot.defaultInputUID ?? "none")\nBlackHole 2ch: \(snapshot.blackHole?.uid ?? "absent")")
            for d in snapshot.devices {
                print("\(d.name) | uid=\(d.uid) | manufacturer=\(d.manufacturer) | transport=\(d.transport) | in=\(d.inputChannels) out=\(d.outputChannels) | rate=\(d.sampleRate) available=\(d.availableSampleRates) | buffer=\(d.bufferRange.minimum)...\(d.bufferRange.maximum) | latency(in/out)=\(d.inputLatency)/\(d.outputLatency) safety=\(d.inputSafetyOffset)/\(d.outputSafetyOffset) | alive=\(d.alive) eligible=\(d.isEligible(in: snapshot.devices))")
            }
        }
    case "capture":
        guard args.count == 7 else { throw EngineError.invalidArgument(usage) }
        var options: [String: String] = [:]
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--device", "--seconds", "--out"].contains(args[i]), options[args[i]] == nil else { throw EngineError.invalidArgument(usage) }
            options[args[i]] = args[i + 1]
        }
        guard let uid = options["--device"], let duration = options["--seconds"], let seconds = Double(duration), let output = options["--out"], let device = try hardware.devices().first(where: { $0.uid == uid }) else { throw EngineError.invalidArgument("Invalid options or device not found\n" + usage) }
        print(try hardware.capture(device: device, seconds: seconds, destination: URL(fileURLWithPath: output)))
    default: throw EngineError.invalidArgument(usage)
    }
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
