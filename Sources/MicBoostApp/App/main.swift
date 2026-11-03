import AppKit
import MicBoostUI
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var status: NSStatusItem?
    private let panelMenu = NSMenu(title: "MicBoost")
    private var menuHost: NSView?
    private var optionClickMonitor: Any?
    private var settings: NSWindow?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status = item
        panelMenu.autoenablesItems = false
        panelMenu.delegate = self
        let host = NSHostingView(
            rootView: PanelView(model: model)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { [weak self] size in
                    guard let host = self?.menuHost, host.frame.size != size else { return }
                    host.setFrameSize(size)
                })
        host.safeAreaRegions = []
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.autoresizingMask = [.width]
        menuHost = host
        let content = NSMenuItem()
        content.view = host
        content.isEnabled = true
        panelMenu.addItem(content)
        item.menu = panelMenu
        optionClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.status?.button?.window, event.modifierFlags.contains(.option)
                else { return false }
                self.model.processing(!self.model.controls.processingEnabled)
                return true
            }
            return consumed ? nil : event
        }
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
        status?.button?.image = NSImage(systemSymbolName: model.icon, accessibilityDescription: nil)
        status?.button?.image?.isTemplate = true
        status?.button?.setAccessibilityLabel(
            "MicBoost, \(model.message ?? localized(model.controls.processingEnabled ? "Active" : "Stopped")), \(AppModel.gainLabel(model.controls.gainDB))"
        )
    }
    private func showPanel() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.status?.button?.performClick(nil) }
        }
    }
    private func closePanel() {
        panelMenu.cancelTracking()
    }
    func menuWillOpen(_ menu: NSMenu) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        status?.button?.highlight(true)
        model.setPanelVisible(true)
    }
    func menuDidClose(_ menu: NSMenu) {
        model.setPanelVisible(false)
        status?.button?.highlight(false)
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
    func applicationWillTerminate(_ notification: Notification) {
        if let optionClickMonitor { NSEvent.removeMonitor(optionClickMonitor) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        closePanel()
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
