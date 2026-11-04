import AppKit
import MicBoostCore
import MicBoostUI
import ScreenCaptureKit
import SwiftUI

/// The offscreen window is key and main so AppKit draws active controls (a native switch in
/// an inactive window paints the gray track even when its value is on).
private final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

enum CaptureError: Error { case noMenuWindow, emptyCapture }

/// Renders the real status menu. The panel is an `NSMenu` of native items, so the only faithful
/// image is the menu the WindowServer composites: the helper opens the menu built by
/// `PanelMenuController`, captures its own menu windows with ScreenCaptureKit, crops the menu's
/// content view and closes the menu again (docs/ui.md "Renderização e verificação").
@MainActor final class MenuCapture: NSObject {
    private let menu: NSMenu
    private var image: NSImage?
    private var failure: Error?
    private var finished = false

    init(menu: NSMenu) { self.menu = menu }

    /// Pops the menu, captures it from the tracking loop and closes it again. A menu closes on
    /// any event outside it, so an attempt may end before the capture; the caller retries.
    func run() throws -> NSImage {
        // The first open measures the menu's own row insets; a warm-up open makes the capture
        // use them instead of the initial layout.
        warmUp()
        var lastError: Error = CaptureError.emptyCapture
        for index in 0..<4 {
            if index > 0 { drain(seconds: 0.25) }
            do {
                if let image = try attempt() { return image }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func warmUp() {
        let timer = Timer(timeInterval: 0.2, repeats: false) { [self] _ in
            MainActor.assumeIsolated { self.menu.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        menu.popUp(positioning: nil, at: NSPoint(x: screen.maxX - 420, y: screen.maxY - 120), in: nil)
        timer.invalidate()
        drain(seconds: 0.2) { false }
    }

    private func attempt() throws -> NSImage? {
        image = nil
        failure = nil
        finished = false
        // The capture runs from the tracking loop, which is the only moment the menu window
        // exists and the WindowServer composites it.
        let timer = Timer(timeInterval: 0.25, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    do {
                        self.image = try await self.grab()
                    } catch {
                        self.failure = error
                    }
                    self.finished = true
                    self.menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        menu.popUp(positioning: nil, at: NSPoint(x: screen.maxX - 420, y: screen.maxY - 120), in: nil)
        timer.invalidate()
        // A dismissed menu ends the tracking loop before the capture: wait for the capture in
        // flight and let the caller try again.
        drain(seconds: 2) { self.finished }
        if let failure { throw failure }
        return image
    }

    private func drain(seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func grab() async throws -> NSImage {
        // The WindowServer lists closed menu windows for a moment and the offscreen settings
        // window is not capturable, so the target comes from the live AppKit window that holds
        // the open menu.
        guard let popup = menu.items.compactMap({ $0.view?.window }).first else { throw CaptureError.noMenuWindow }
        let window =
            NSApp.windows.first { $0.isVisible && $0 !== popup && $0.frame.contains(popup.frame) }
            ?? NSApp.windows.first { $0.isVisible && $0 !== popup && $0.frame.origin.x > -10000 }
        guard let window else { throw CaptureError.noMenuWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == window.windowNumber }) else {
            throw CaptureError.noMenuWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * scale)
        configuration.height = Int(target.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        guard let content = window.contentView else { throw CaptureError.noMenuWindow }
        // The captured image covers the whole window; the panel is the frame of its content.
        let frame = content.frame
        let crop = CGRect(
            x: frame.minX * scale,
            y: (window.frame.height - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale)
        guard let cropped = image.cropping(to: crop) else { throw CaptureError.emptyCapture }
        let size = NSSize(width: crop.width / scale, height: crop.height / scale)
        return NSImage(cgImage: cropped, size: size)
    }
}

@MainActor func sampleModel(kind: String) -> AppModel {
    let model = AppModel(statusGrace: .zero)
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
    model.expanded = kind == "eq"
    model.limitingUntil = .distantPast
    model.apply(
        .init(
            state: .running, source: source, blackHole: blackHole,
            defaultInput: .init(isBlackHole: true), defaultInputName: "MicBoost", sampleRate: 48000,
            bufferFrames: 256, reportedLatencyMs: 15.3, overloads: 0, cycles: 412_000,
            inputMissing: 0, nonfiniteResets: 0))
    model.inputDB = -14
    model.outputDB = -8
    if kind == "error" {
        model.error = .blackHoleMissing
    }
    return model
}

/// The settings window keeps the offscreen window with `cacheDisplay`: its content is SwiftUI
/// on AppKit controls, without a menu for the WindowServer to compose.
@MainActor func captureSettings(dark: Bool, directory: URL, locale: Locale, write: Bool) throws {
    let model = sampleModel(kind: "settings")
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(
        rootView: SettingsView(model: model).background(.background)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.appearsActive, true).environment(\.locale, locale))
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
    try png.write(to: directory.appendingPathComponent("settings-\(dark ? "dark" : "light").png"))
}

@MainActor func render() throws {
    // The README is written in English, so the renders use the development language and
    // its number format regardless of the maintainer's system language.
    UILanguage.override = "en"
    AppModel.formatLocaleOverride = UILanguage.locale
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for kind in ["eq", "panel", "error"] {
            let panel = PanelMenuController(model: sampleModel(kind: kind))
            let image = try MenuCapture(menu: panel.menu).run()
            guard let png = image.pngData else { continue }
            try png.write(to: directory.appendingPathComponent("\(kind)-\(dark ? "dark" : "light").png"))
        }
        try captureSettings(dark: dark, directory: directory, locale: UILanguage.locale, write: true)
    }
    NSApp.appearance = nil
}

extension NSImage {
    fileprivate var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Runs the render inside the app event loop so the helper can become active and AppKit paints
/// active controls: an inactive app draws every switch with the gray track. The render is
/// synchronous on the main actor, because popping a menu blocks in a nested run loop: a
/// main-actor task would keep the actor busy and the capture scheduled from the tracking loop
/// could never start.
@MainActor final class RenderDelegate: NSObject, NSApplicationDelegate {
    private var attempts = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        waitForActive()
    }

    private func waitForActive() {
        attempts += 1
        guard NSApp.isActive || attempts > 40 else {
            NSApp.activate(ignoringOtherApps: true)
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.waitForActive() }
            }
            RunLoop.main.add(timer, forMode: .default)
            return
        }
        FileHandle.standardError.write(Data("active=\(NSApp.isActive)\n".utf8))
        MainActor.assumeIsolated {
            do {
                try render()
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = RenderDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
