import CoreAudio
public struct AudioRange: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public init(_ minimum: Double, _ maximum: Double) { self.minimum = minimum; self.maximum = maximum }
}
public struct AudioDevice: Codable, Equatable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var manufacturer: String = ""
    public var transport: UInt32 = 0
    public var inputChannels: UInt32 = 0
    public var outputChannels: UInt32 = 0
    public var sampleRate: Double = 48000
    public var availableSampleRates: [AudioRange] = []
    public var bufferRange: AudioRange = .init(0, 0)
    public var alive: Bool = true
    public var inputLatency: UInt32 = 0
    public var outputLatency: UInt32 = 0
    public var inputSafetyOffset: UInt32 = 0
    public var outputSafetyOffset: UInt32 = 0
    public var subdeviceUIDs: [String] = []
    public init(id: AudioObjectID, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
    public var isBlackHole: Bool { uid.hasPrefix("BlackHole") || name.hasPrefix("BlackHole") || (manufacturer.contains("Existential Audio") && name.contains("BlackHole")) }
    public var isBlackHole2ch: Bool { uid == "BlackHole2ch_UID" || (manufacturer.contains("Existential Audio") && name.contains("BlackHole") && outputChannels == 2) }
    public func isEligible(in devices: [AudioDevice]) -> Bool {
        func containsBlackHole(_ device: AudioDevice, visited: Set<String>) -> Bool {
            if device.isBlackHole { return true }
            guard !visited.contains(device.uid) else { return false }
            let seen = visited.union([device.uid])
            return device.subdeviceUIDs.contains { uid in
                uid.hasPrefix("BlackHole") || devices.contains { $0.uid == uid && containsBlackHole($0, visited: seen) }
            }
        }
        return inputChannels > 0 && uid != "io.github.vittau.MicBoost.engine" && !containsBlackHole(self, visited: [])
    }
}
