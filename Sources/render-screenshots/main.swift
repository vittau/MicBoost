import AppKit
import MicBoostCore
import MicBoostUI
import SwiftUI

@MainActor func render() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AppModel()
    model.controls.gainDB = 12
    var source = AudioDevice(id: 1, uid: "sample", name: "USB Microphone")
    source.inputChannels = 2
    model.devices = [source]
    model.controls.selectedInputUID = source.uid
    model.inputDB = -18
    model.outputDB = -6
    for dark in [false, true] {
        let scheme: ColorScheme = dark ? .dark : .light
        for kind in ["panel", "eq", "settings", "error"] {
            model.expanded = kind == "eq"
            model.inputDB = kind == "panel" ? 0 : -18
            model.outputDB = kind == "panel" ? -1 : -6
            model.limitingUntil = kind == "panel" ? .distantFuture : .distantPast
            model.error = kind == "error" ? .blackHoleMissing : nil
            let view = kind == "settings" ? AnyView(SettingsView(model: model)) : AnyView(PanelView(model: model))
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(
                rootView: view.padding(0).background(.background).environment(\.colorScheme, scheme).environment(
                    \.appearsActive, true))
            host.appearance = appearance
            let size = host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.appearance = appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("\(kind)-\(dark ? "dark" : "light").png"))
                }
            }
            window.close()
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
try render()
