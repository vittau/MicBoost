import MicBoostCore
import Testing

@Test func processingSettersPersistAndResetOnlyBands() async throws {
    let storage = MemorySettingsStorage()
    let store = SettingsStore(storage: storage)
    let controller = EngineController(hardware: FakeAudioHardware(), settings: store)
    await controller.setGain(db: 12)
    await controller.setMuted(true)
    await controller.setEQEnabled(false)
    await controller.setBand(.low, frequency: 250, gainDB: 8)
    await controller.setBand(.mid, frequency: 800, gainDB: -6, q: 2)
    await controller.setBand(.high, frequency: 9000, gainDB: 4)
    await controller.setChannelSelection(.stereo(firstChannel: 3), forUID: "source")
    await store.flush()
    let loaded = SettingsStore(storage: storage)
    let values = await loaded.current
    #expect(values.gainDB == 12 && values.muted && !values.eq.enabled)
    #expect(values.eq.low.frequency == 250 && values.eq.mid.q == 2 && values.eq.high.gainDB == 4)
    #expect(values.channelSelectionByUID["source"] == .stereo(firstChannel: 3))
    await controller.resetEQ()
    await store.flush()
    let reset = await store.current
    #expect(reset.eq.low == EQSettings().low)
    #expect(reset.eq.mid == EQSettings().mid)
    #expect(reset.eq.high == EQSettings().high)
    #expect(!reset.eq.enabled && reset.muted && reset.gainDB == 12)
    #expect(reset.channelSelectionByUID == values.channelSelectionByUID)
    #expect(await controller.status().state == .stopped)
    #expect(await controller.meters().outputPeak == 0)
    await controller.setGain(db: 100)
    #expect(await store.current.gainDB == 24)
}

@Test func liveControlsKeepEngineRunning() async throws {
    let fake = FakeAudioHardware()
    var source = AudioDevice(id: 1, uid: "test.source", name: "Source")
    source.inputChannels = 1
    var destination = AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole")
    destination.inputChannels = 2
    destination.outputChannels = 2
    fake.deviceList = [source, destination]
    let store = SettingsStore(storage: MemorySettingsStorage())
    let sourceUID = source.uid
    await store.update {
        $0.gainDB = 6
        $0.muted = true
        $0.eq.low.gainDB = 4
        $0.channelSelectionByUID[sourceUID] = .mono(channel: 1)
    }
    let controller = EngineController(hardware: fake, settings: store)
    try await controller.start(inputUID: source.uid)
    await controller.setGain(db: 12)
    await controller.setMuted(false)
    await controller.setEQEnabled(false)
    await controller.setBand(.mid, frequency: 800, gainDB: 4, q: 2)
    await controller.setChannelSelection(.monoMix, forUID: source.uid)
    await controller.resetEQ()
    let status = await controller.status()
    #expect(status.state == .running && status.source?.uid == source.uid)
    #expect(status.bufferFrames == 256)
    #expect(await store.current.gainDB == 12)
    try await controller.stop()
}
