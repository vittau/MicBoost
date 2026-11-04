import AppKit
import MicBoostUI
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var panel: PanelMenuController?
    private var status: NSStatusItem?
    private var optionClickMonitor: Any?
    private var settings: NSWindow?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status = item
        let panel = PanelMenuController(model: model)
        self.panel = panel
        panel.onOpen = { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.status?.button?.highlight(true)
        }
        panel.onClose = { [weak self] in self?.status?.button?.highlight(false) }
        item.menu = panel.menu
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
        model.onMeters = { [weak self] in self?.refreshMeters() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
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
        status?.button?.image = StatusItemImage.image(symbol: model.icon)
        status?.button?.image?.isTemplate = true
        status?.button?.setAccessibilityLabel(
            "MicBoost, \(model.message ?? localized(model.controls.processingEnabled ? "Active" : "Stopped")), \(AppModel.gainLabel(model.controls.gainDB))"
        )
        refreshPanel()
    }
    /// Rows repaint only while the panel is open; opening it refreshes everything.
    private func refreshPanel() {
        guard model.panelVisible else { return }
        panel?.refresh()
    }
    private func refreshMeters() {
        guard model.panelVisible else { return }
        panel?.refreshLive()
    }
    private func showPanel() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.status?.button?.performClick(nil) }
        }
    }
    private func closePanel() {
        panel?.close()
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
    @objc private func activated() { model.applicationDidBecomeActive() }
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
