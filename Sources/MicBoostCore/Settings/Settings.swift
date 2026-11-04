import Foundation

/// Persistent settings of the app (docs/architecture.md "Persistência").
///
/// Ranges and defaults come from the specification: gain from docs/dsp.md
/// "Ganho", the three EQ bands from "Equalizador" and the channel modes from
/// docs/audio-engine.md "Canais".
public struct Settings: Codable, Equatable, Sendable {
    /// Bumped whenever the stored shape changes; unknown versions load defaults.
    public static let currentSchemaVersion = 1
    public static let allowedBufferFrames = [64, 128, 256, 512, 1024]
    public static let gainRange = -12.0...24.0

    public var schemaVersion: Int
    public var manageDefaultInput: Bool
    public var processingEnabled: Bool
    public var selectedInputUID: String?
    public var gainDB: Double
    public var muted: Bool
    public var eq: EQSettings
    public var channelSelectionByUID: [String: ChannelSelection]
    /// Last name each source reported, keyed by UID, so a source that is absent keeps
    /// its name in the UI after a relaunch (docs/ui.md "Painel").
    public var knownSourceNames: [String: String]
    public var bufferFrames: Int
    public var previousDefaultInputUID: String?
    public var defaultInputManaged: Bool

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        processingEnabled: Bool = true,
        manageDefaultInput: Bool = true,
        selectedInputUID: String? = nil,
        gainDB: Double = 0,
        muted: Bool = false,
        eq: EQSettings = EQSettings(),
        channelSelectionByUID: [String: ChannelSelection] = [:],
        knownSourceNames: [String: String] = [:],
        bufferFrames: Int = 256,
        previousDefaultInputUID: String? = nil,
        defaultInputManaged: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.processingEnabled = processingEnabled
        self.manageDefaultInput = manageDefaultInput
        self.selectedInputUID = selectedInputUID
        self.gainDB = gainDB
        self.muted = muted
        self.eq = eq
        self.channelSelectionByUID = channelSelectionByUID
        self.knownSourceNames = knownSourceNames
        self.bufferFrames = bufferFrames
        self.previousDefaultInputUID = previousDefaultInputUID
        self.defaultInputManaged = defaultInputManaged
    }

    /// Defaults per field, so data written by an older build keeps its valid keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        manageDefaultInput = try container.decodeIfPresent(Bool.self, forKey: .manageDefaultInput) ?? true
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        processingEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .processingEnabled)
            ?? defaults.processingEnabled
        selectedInputUID = try container.decodeIfPresent(String.self, forKey: .selectedInputUID)
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? defaults.gainDB
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? defaults.muted
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? defaults.eq
        channelSelectionByUID =
            try container.decodeIfPresent(
                [String: ChannelSelection].self, forKey: .channelSelectionByUID) ?? defaults.channelSelectionByUID
        knownSourceNames =
            try container.decodeIfPresent([String: String].self, forKey: .knownSourceNames)
            ?? defaults.knownSourceNames
        bufferFrames = try container.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? defaults.bufferFrames
        previousDefaultInputUID = try container.decodeIfPresent(String.self, forKey: .previousDefaultInputUID)
        defaultInputManaged =
            try container.decodeIfPresent(Bool.self, forKey: .defaultInputManaged)
            ?? defaults.defaultInputManaged
    }

    /// Keeps persisted values inside the documented ranges; used after loading.
    public func sanitized() -> Settings {
        var copy = self
        copy.schemaVersion = Settings.currentSchemaVersion
        copy.gainDB = clampedValue(gainDB, to: Settings.gainRange)
        copy.bufferFrames = Self.allowedBufferFrames.contains(bufferFrames) ? bufferFrames : 256
        copy.eq = eq.sanitized()
        copy.channelSelectionByUID = channelSelectionByUID.filter { _, selection in selection.isValid }
            .mapValues { $0 == .auto ? .mono(channel: 1) : $0 }
        copy.knownSourceNames = knownSourceNames.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        return copy
    }
}

public struct EQSettings: Codable, Equatable, Sendable {
    public static let gainRange = -12.0...12.0
    public static let lowFrequencyRange = 40.0...500.0
    public static let midFrequencyRange = 200.0...6000.0
    public static let midQRange = 0.3...4.0
    public static let highFrequencyRange = 2000.0...14000.0

    public var enabled: Bool
    public var low: EQShelfBand
    public var mid: EQPeakingBand
    public var high: EQShelfBand

    public init(
        enabled: Bool = true,
        low: EQShelfBand = EQShelfBand(frequency: 70, gainDB: -6),
        mid: EQPeakingBand = EQPeakingBand(frequency: 3000, gainDB: 2, q: 1),
        high: EQShelfBand = EQShelfBand(frequency: 8000, gainDB: 1.5)
    ) {
        self.enabled = enabled
        self.low = low
        self.mid = mid
        self.high = high
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EQSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        low = try container.decodeIfPresent(EQShelfBand.self, forKey: .low) ?? defaults.low
        mid = try container.decodeIfPresent(EQPeakingBand.self, forKey: .mid) ?? defaults.mid
        high = try container.decodeIfPresent(EQShelfBand.self, forKey: .high) ?? defaults.high
    }

    public func sanitized() -> EQSettings {
        var copy = self
        copy.low.frequency = clampedValue(low.frequency, to: EQSettings.lowFrequencyRange)
        copy.low.gainDB = clampedValue(low.gainDB, to: EQSettings.gainRange)
        copy.mid.frequency = clampedValue(mid.frequency, to: EQSettings.midFrequencyRange)
        copy.mid.gainDB = clampedValue(mid.gainDB, to: EQSettings.gainRange)
        copy.mid.q = clampedValue(mid.q, to: EQSettings.midQRange)
        copy.high.frequency = clampedValue(high.frequency, to: EQSettings.highFrequencyRange)
        copy.high.gainDB = clampedValue(high.gainDB, to: EQSettings.gainRange)
        return copy
    }
}

public struct EQShelfBand: Codable, Equatable, Sendable {
    public var frequency: Double
    public var gainDB: Double
    public init(frequency: Double, gainDB: Double) {
        self.frequency = frequency
        self.gainDB = gainDB
    }
}

public struct EQPeakingBand: Codable, Equatable, Sendable {
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public init(frequency: Double, gainDB: Double, q: Double) {
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }
}

/// Channel mode of one source device (docs/audio-engine.md "Canais").
///
/// Channels are one-based, matching the UI and the DSP API.
public enum ChannelSelection: Codable, Equatable, Sendable {
    case auto
    case mono(channel: Int)
    case monoMix
    case stereo(firstChannel: Int)

    public var isValid: Bool {
        switch self {
        case .auto, .monoMix: return true
        case .mono(let channel): return channel >= 1
        case .stereo(let firstChannel): return firstChannel >= 1
        }
    }

    private enum Mode: String, Codable {
        case auto, mono, monoMix, stereo
    }

    private enum CodingKeys: String, CodingKey {
        case mode, channel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .auto:
            self = .auto
        case .monoMix:
            self = .monoMix
        case .mono:
            let channel = try container.decode(Int.self, forKey: .channel)
            guard channel >= 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .channel, in: container, debugDescription: "Channel is one-based")
            }
            self = .mono(channel: channel)
        case .stereo:
            let channel = try container.decode(Int.self, forKey: .channel)
            guard channel >= 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .channel, in: container, debugDescription: "Channel is one-based")
            }
            self = .stereo(firstChannel: channel)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode(Mode.auto, forKey: .mode)
        case .monoMix:
            try container.encode(Mode.monoMix, forKey: .mode)
        case .mono(let channel):
            try Self.checkChannel(channel, in: container)
            try container.encode(Mode.mono, forKey: .mode)
            try container.encode(channel, forKey: .channel)
        case .stereo(let firstChannel):
            try Self.checkChannel(firstChannel, in: container)
            try container.encode(Mode.stereo, forKey: .mode)
            try container.encode(firstChannel, forKey: .channel)
        }
    }

    private static func checkChannel(_ channel: Int, in container: KeyedEncodingContainer<CodingKeys>) throws {
        guard channel >= 1 else {
            throw EncodingError.invalidValue(
                channel,
                EncodingError.Context(codingPath: container.codingPath, debugDescription: "Channel is one-based"))
        }
    }
}

private func clampedValue(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}
