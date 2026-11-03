import AppKit
import MicBoostUI
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var status: NSStatusItem?
    private let popover = NSPopover()
    private var settings: NSWindow?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(
            rootView: PanelView(model: model).onExitCommand { [weak self] in
                self?.closePanel()
            })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
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
    @objc private func toggle() {
        if NSEvent.modifierFlags.contains(.option) {
            model.processing(!model.controls.processingEnabled)
            return
        }
        if popover.isShown { closePanel() } else { showPanel() }
    }
    private func showPanel() {
        guard let button = status?.button else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func closePanel() {
        popover.performClose(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        status?.button?.highlight(true)
        model.setPanelVisible(true)
    }
    func popoverWillClose(_ notification: Notification) {
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
