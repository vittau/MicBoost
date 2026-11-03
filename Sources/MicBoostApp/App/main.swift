import AppKit
import MicBoostUI
import SwiftUI

@MainActor final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var closeAction: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { closeAction() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var status: NSStatusItem?
    private var panel: MenuBarPanel?
    private var settings: NSWindow?
    private var outside: Any?
    private var local: Any?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onQuit = { NSApplication.shared.terminate(nil) }
        model.onUpdate = { [weak self] in self?.update() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        Task {
            await model.launch()
            update()
            showPanel()
        }
    }
    private func configureMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(title: "MicBoost", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "MicBoost")
        let settingsItem = NSMenuItem(
            title: localized("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: localized("Quit MicBoost"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let editItem = NSMenuItem(title: localized("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: localized("Edit"))
        editMenu.addItem(withTitle: localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: localized("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }
    private func update() {
        if let panel, panel.isVisible, let material = panel.contentView, let host = material.subviews.first {
            let size = host.fittingSize
            if abs(size.height - panel.frame.height) > 1 {
                let top = panel.frame.maxY
                panel.setContentSize(size)
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - size.height))
            }
        }
        status?.button?.image = NSImage(systemSymbolName: model.icon, accessibilityDescription: nil)
        status?.button?.image?.isTemplate = true
        status?.button?.setAccessibilityLabel(
            "MicBoost, \(model.message ?? localized(model.controls.processingEnabled ? "Active" : "Stopped")), \(AppModel.gainLabel(model.controls.gainDB))"
        )
    }
    @objc private func toggle() {
        if NSEvent.modifierFlags.contains(.option) {
            model.processing(!model.controls.processingEnabled)
            return
        }
        if panel?.isVisible == true { closePanel() } else { showPanel() }
    }
    private func showPanel() {
        let host = NSHostingView(rootView: PanelView(model: model))
        let size = host.fittingSize
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        panel.contentView = material
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.closeAction = { [weak self] in self?.closePanel() }
        if let button = status?.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = window.screen?.visibleFrame ?? anchor
            panel.setFrameOrigin(
                NSPoint(
                    x: min(max(anchor.maxX - 320, visible.minX), visible.maxX - 320),
                    y: max(visible.minY, anchor.minY - size.height - 5)))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        model.setPanelVisible(true)
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel && event.window !== self?.status?.button?.window { self?.closePanel() }
            }
            return event
        }
    }
    private func closePanel() {
        panel?.orderOut(nil)
        model.setPanelVisible(false)
        if let outside {
            NSEvent.removeMonitor(outside)
            self.outside = nil
        }
        if let local {
            NSEvent.removeMonitor(local)
            self.local = nil
        }
    }
    @objc private func showSettings() {
        closePanel()
        if settings == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = localized("MicBoost Settings")
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settings = window
        }
        model.settingsVisible = true
        settings?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model.settingsVisible = false }
    @objc private func sleep() { Task { try? await model.engine.willSleep() } }
    @objc private func wake() { Task { await model.engine.didWake() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        Task {
            do {
                try await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
