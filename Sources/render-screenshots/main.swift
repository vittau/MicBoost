import AppKit
import MicBoostCore
import MicBoostUI
import SwiftUI

@MainActor func capture(
    model: AppModel, kind: String, dark: Bool, directory: URL, locale: Locale, write: Bool
) throws {
    let scheme: ColorScheme = dark ? .dark : .light
    model.expanded = kind == "eq"
    model.limitingUntil = .distantPast
    model.error = kind == "error" ? .blackHoleMissing : nil
    let view = kind == "settings" ? AnyView(SettingsView(model: model)) : AnyView(PanelView(model: model))
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(
        rootView: view.padding(0).background(.background).environment(\.colorScheme, scheme).environment(
            \.appearsActive, true
        ).environment(\.locale, locale))
    host.appearance = appearance
    let size = host.fittingSize
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.displayIfNeeded()
    defer { window.close() }
    guard write, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try png.write(to: directory.appendingPathComponent("\(kind)-\(dark ? "dark" : "light").png"))
}

@MainActor func render() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AppModel()
    var source = AudioDevice(id: 2, uid: "usb.microphone", name: "USB Microphone")
    source.inputChannels = 2
    source.sampleRate = 48000
    var blackHole = AudioDevice(id: 3, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    blackHole.inputChannels = 2
    blackHole.outputChannels = 2
    model.devices = [source, blackHole]
    model.controls.selectedInputUID = source.uid
    model.controls.gainDB = 6
    // Sample state of a running bridge: MicBoost is the system input and the diagnostics
    // show a 48 kHz, 256-frame engine with its reported latency.
    model.apply(
        .init(
            state: .running, source: source, blackHole: blackHole,
            defaultInput: .init(isBlackHole: true), defaultInputName: "MicBoost", sampleRate: 48000,
            bufferFrames: 256, reportedLatencyMs: 15.3, overloads: 0, cycles: 412_000,
            inputMissing: 0, nonfiniteResets: 0))
    model.inputDB = -14
    model.outputDB = -8
    let locale = UILanguage.locale
    for dark in [false, true] {
        for kind in ["panel", "eq", "settings", "error"] {
            try capture(model: model, kind: kind, dark: dark, directory: directory, locale: locale, write: true)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
try render()
