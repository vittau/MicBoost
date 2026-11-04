import Foundation
import Testing

@testable import MicBoostCore

@Test func settingsDefaults() {
    let settings = Settings()
    #expect(settings.schemaVersion == Settings.currentSchemaVersion)
    #expect(settings.processingEnabled)
    #expect(settings.selectedInputUID == nil)
    #expect(settings.gainDB == 0)
    #expect(!settings.muted)
    #expect(settings.eq.enabled)
    #expect(settings.eq.low == EQShelfBand(frequency: 70, gainDB: -6))
    #expect(settings.eq.mid == EQPeakingBand(frequency: 3000, gainDB: 2, q: 1))
    #expect(settings.eq.high == EQShelfBand(frequency: 8000, gainDB: 1.5))
    #expect(settings.channelSelectionByUID.isEmpty)
    #expect(settings.knownSourceNames.isEmpty)
    #expect(settings.bufferFrames == 256)
    #expect(settings.previousDefaultInputUID == nil)
    #expect(!settings.defaultInputManaged)
}

@Test func settingsRoundTrip() throws {
    var settings = Settings(
        processingEnabled: false,
        selectedInputUID: "usb",
        gainDB: 6.5,
        muted: true,
        bufferFrames: 512,
        previousDefaultInputUID: "internal",
        defaultInputManaged: true)
    settings.eq.enabled = false
    settings.eq.low = EQShelfBand(frequency: 80, gainDB: -3)
    settings.eq.mid = EQPeakingBand(frequency: 2500, gainDB: 4.5, q: 2)
    settings.eq.high = EQShelfBand(frequency: 8000, gainDB: 2)
    settings.channelSelectionByUID = [
        "usb": .stereo(firstChannel: 1),
        "internal": .mono(channel: 2),
        "mix": .monoMix,
        "auto": .auto,
    ]
    settings.knownSourceNames = ["usb": "USB Microphone", "internal": "Built-in Microphone"]
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
}

@Test func channelSelectionRoundTrip() throws {
    let selections: [ChannelSelection] = [.auto, .monoMix, .mono(channel: 1), .stereo(firstChannel: 3)]
    for selection in selections {
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(ChannelSelection.self, from: data) == selection)
    }
}

@Test func invalidChannelSelectionIsRejected() throws {
    let zeroChannel = Data(#"{"mode":"mono","channel":0}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ChannelSelection.self, from: zeroChannel) }
    let unknownMode = Data(#"{"mode":"surround","channel":1}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ChannelSelection.self, from: unknownMode) }
    #expect(throws: (any Error).self) { try JSONEncoder().encode(ChannelSelection.mono(channel: 0)) }
}

@Test func storedSettingsLoadBack() async throws {
    let storage = MemorySettingsStorage()
    try storage.seed(Settings(gainDB: 3, bufferFrames: 128, defaultInputManaged: true))
    let store = SettingsStore(storage: storage)
    let settings = await store.current
    #expect(settings.gainDB == 3)
    #expect(settings.bufferFrames == 128)
    #expect(settings.defaultInputManaged)
}

@Test func corruptDataFallsBackToDefaults() async throws {
    let storage = MemorySettingsStorage()
    storage.seed(Data("not a settings payload".utf8))
    let store = SettingsStore(storage: storage)
    #expect(await store.current == Settings())
}

@Test func unknownSchemaFallsBackToDefaults() async throws {
    let storage = MemorySettingsStorage()
    try storage.seed(Settings(schemaVersion: Settings.currentSchemaVersion + 1, gainDB: 9))
    let store = SettingsStore(storage: storage)
    #expect(await store.current == Settings())
}

@Test func partialDataKeepsDefaults() async throws {
    let storage = MemorySettingsStorage()
    storage.seed(Data(#"{"schemaVersion":1,"gainDB":4}"#.utf8))
    let store = SettingsStore(storage: storage)
    let settings = await store.current
    #expect(settings.gainDB == 4)
    #expect(settings.bufferFrames == 256)
    #expect(settings.eq == EQSettings())
    #expect(settings.knownSourceNames.isEmpty)
}

@Test func knownSourceNamesRoundTripAndDropEmptyEntries() async throws {
    let storage = MemorySettingsStorage()
    try storage.seed(Settings(knownSourceNames: ["usb": "USB Microphone", "": "No UID", "gone": ""]))
    let settings = await SettingsStore(storage: storage).current
    #expect(settings.knownSourceNames == ["usb": "USB Microphone"])
}

@Test func outOfRangeValuesAreClamped() async throws {
    let storage = MemorySettingsStorage()
    try storage.seed(
        Settings(
            gainDB: 99,
            eq: EQSettings(
                low: EQShelfBand(frequency: 5, gainDB: -40),
                mid: EQPeakingBand(frequency: 30000, gainDB: 40, q: 0),
                high: EQShelfBand(frequency: 100, gainDB: 40)),
            bufferFrames: 32))
    let store = SettingsStore(storage: storage)
    let settings = await store.current
    #expect(settings.gainDB == Settings.gainRange.upperBound)
    #expect(settings.bufferFrames == 256)
    #expect(settings.eq.low.frequency == EQSettings.lowFrequencyRange.lowerBound)
    #expect(settings.eq.low.gainDB == EQSettings.gainRange.lowerBound)
    #expect(settings.eq.mid.frequency == EQSettings.midFrequencyRange.upperBound)
    #expect(settings.eq.mid.gainDB == EQSettings.gainRange.upperBound)
    #expect(settings.eq.mid.q == EQSettings.midQRange.lowerBound)
    #expect(settings.eq.high.frequency == EQSettings.highFrequencyRange.lowerBound)
    #expect(settings.eq.high.gainDB == EQSettings.gainRange.upperBound)
}

@Test func invalidChannelSelectionIsDropped() {
    let settings = Settings(
        channelSelectionByUID: ["usb": .mono(channel: 0), "internal": .mono(channel: 1)])
    let sanitized = settings.sanitized()
    #expect(sanitized.channelSelectionByUID.count == 1)
    #expect(sanitized.channelSelectionByUID["internal"] == .mono(channel: 1))
}

@Test func debounceCoalescesWrites() async throws {
    let storage = MemorySettingsStorage()
    let store = SettingsStore(storage: storage)
    for step in 1...5 {
        await store.update { $0.gainDB = Double(step) }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(storage.writes == 0)
    try await Task.sleep(for: .milliseconds(500))
    #expect(storage.writes == 1)
    #expect(storage.decoded?.gainDB == 5)
}

@Test func unchangedUpdateDoesNotWrite() async throws {
    let storage = MemorySettingsStorage()
    let store = SettingsStore(storage: storage)
    await store.update { $0.gainDB = 0 }
    await store.flush()
    #expect(storage.writes == 0)
}

@Test func defaultInputFieldsAreSavedImmediately() async throws {
    let storage = MemorySettingsStorage()
    let store = SettingsStore(storage: storage)
    await store.updateDefaultInput {
        $0.previousDefaultInputUID = "internal"
        $0.defaultInputManaged = true
    }
    #expect(storage.writes == 1)
    #expect(storage.decoded?.previousDefaultInputUID == "internal")
    #expect(storage.decoded?.defaultInputManaged == true)
}

@Test func defaultInputWriteFlushesPendingChanges() async throws {
    let storage = MemorySettingsStorage()
    let store = SettingsStore(storage: storage)
    await store.update { $0.gainDB = 7 }
    await store.updateDefaultInput { $0.defaultInputManaged = true }
    #expect(storage.writes == 1)
    #expect(storage.decoded?.gainDB == 7)
    #expect(storage.decoded?.defaultInputManaged == true)
    try await Task.sleep(for: .milliseconds(500))
    #expect(storage.writes == 1)
}

@Test func storedAutomaticChannelSelectionUsesMonoOne() async throws {
    let storage = MemorySettingsStorage()
    try storage.seed(Settings(channelSelectionByUID: ["automatic": .auto, "chosen": .mono(channel: 2)]))
    let store = SettingsStore(storage: storage)
    let settings = await store.current
    #expect(settings.channelSelectionByUID["automatic"] == .mono(channel: 1))
    #expect(settings.channelSelectionByUID["chosen"] == .mono(channel: 2))
}
