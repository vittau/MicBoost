import AppKit
import MicBoostCore
import MicBoostUI
import SwiftUI

/// The offscreen window is key and main so AppKit draws active controls (a native switch in
/// an inactive window paints the gray track even when its value is on).
private final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

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
    let window = RenderWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    host.layoutSubtreeIfNeeded()
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.displayIfNeeded()
    defer { window.close() }
    guard write, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try png.write(to: directory.appendingPathComponent("\(kind)-\(dark ? "dark" : "light").png"))
}

@MainActor func render() throws {
    // The README is written in English, so the renders use the development language and
    // its number format regardless of the maintainer's system language.
    UILanguage.override = "en"
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AppModel()
    var source = AudioDevice(id: 2, uid: "usb.microphone", name: "USB Microphone")
    source.inputChannels = 2
    source.sampleRate = 48000
    source.bufferRange = .init(8, 2250)
    source.inputLatency = 38
    source.inputSafetyOffset = 38
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
/// Runs the render inside the app event loop so the helper can become active and AppKit
/// paints active controls: an inactive app draws every switch with the gray track.
final class RenderDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            // AppKit draws inactive controls gray, so the helper waits to be the active app.
            for _ in 0..<40 where !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .milliseconds(50))
            }
            FileHandle.standardError.write(Data("active=\(NSApp.isActive)\n".utf8))
            do { try render() } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
        }
    }
}
let app = NSApplication.shared
let delegate = RenderDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
