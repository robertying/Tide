import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let dimmer = Dimmer()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private weak var levelSlider: NSSlider?
    private weak var levelLabel: NSTextField?

    func applicationDidFinishLaunching(_ note: Notification) {
        // One copy only: two dimmers would fight over the display.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            Log.write("app", "another Tide is already running; exiting")
            exit(0)
        }

        installEditMenu()
        Log.rotate()
        Log.write("app", "Tide \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")

        // Keep the menu slider in step with the volume keys and resyncs while the menu is open.
        NotificationCenter.default.addObserver(forName: VolumeController.levelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.showLevel(Soundbar.shared.controller.shownLevel)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Tide")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // `kill` (SIGTERM) and Ctrl-C go through a normal quit, so a dimmed display is restored.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        dimmer.start()
        Soundbar.shared.start()

        // First run: nothing configured yet, so show where to do it.
        if !UserDefaults.standard.bool(forKey: "app.didShowSettings") {
            UserDefaults.standard.set(true, forKey: "app.didShowSettings")
            showSettings()
        }
    }

    /// A menu bar app has no visible main menu, but text fields still get ⌘X/⌘C/⌘V/⌘A/⌘Z
    /// only through one. This main menu is never shown; it just carries the key equivalents.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ note: Notification) {
        dimmer.stop()
        Log.write("app", "quit")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addToggle(to: menu, "Dim Display When Idle", status: dimmer.status, on: Settings.dimEnabled, #selector(toggleDim))
        // Extra controls show only while their feature is on (same for the soundbar slider below).
        if Settings.dimEnabled {
            let pause = NSMenuItem(title: "Pause Dimming", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if Settings.pausedUntil != nil {
                sub.addItem(item("Resume Now", #selector(resumeDimming)))
                sub.addItem(.separator())
            }
            sub.addItem(item("For 1 Hour", #selector(pauseDimming(_:)), tag: 3600))
            sub.addItem(item("For 3 Hours", #selector(pauseDimming(_:)), tag: 3 * 3600))
            sub.addItem(item("Until Tomorrow", #selector(pauseDimming(_:)), tag: -1))
            pause.submenu = sub
            menu.addItem(pause)
        }

        menu.addItem(.separator())
        let sb = Soundbar.shared
        addToggle(to: menu, "Volume Keys Control Soundbar", status: sb.status, on: Settings.sbEnabled, #selector(toggleSoundbar))
        if Settings.sbEnabled && !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
        } else if Settings.sbEnabled && !sb.tapInstalled {
            menu.addItem(item("Relaunch Tide", #selector(relaunch)))
        }
        if Settings.sbEnabled && Settings.sbConfigured {
            menu.addItem(sliderItem(level: sb.controller.shownLevel))
            sb.controller.resync() // picks up changes from the TV remote; the slider follows via levelChanged
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(toggle("Launch at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tide", #selector(quit), key: "q"))
    }

    /// A toggle with its current status as a subtitle (or as a grey line above it before macOS 14.4).
    private func addToggle(to menu: NSMenu, _ title: String, status: String, on: Bool, _ action: Selector) {
        let t = toggle(title, on: on, action)
        if #available(macOS 14.4, *) {
            t.subtitle = status
        } else {
            menu.addItem(info(status))
        }
        menu.addItem(t)
    }

    private func info(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.tag = tag
        return i
    }

    private func toggle(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    private func sliderItem(level: Int?) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let icon = NSImageView(frame: NSRect(x: 14, y: 5, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Soundbar level")
        icon.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: Double(level ?? 0), minValue: 0, maxValue: Double(Settings.sbMax),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 36, y: 4, width: 164, height: 20)
        slider.isContinuous = true // changes are coalesced, so dragging sets the soundbar live
        let label = NSTextField(labelWithString: level.map(String.init) ?? "–")
        label.frame = NSRect(x: 204, y: 6, width: 30, height: 16)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        [icon, slider, label].forEach(view.addSubview)
        levelSlider = slider
        levelLabel = label
        let i = NSMenuItem()
        i.view = view
        return i
    }

    // MARK: Actions

    @objc private func toggleDim() { Settings.dimEnabled.toggle() }

    @objc private func pauseDimming(_ sender: NSMenuItem) {
        if sender.tag > 0 {
            Settings.pausedUntil = Date().addingTimeInterval(TimeInterval(sender.tag))
        } else {
            let cal = Calendar.current
            Settings.pausedUntil = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
        }
        Log.write("dim", "paused until \(Settings.pausedUntil.map { "\($0)" } ?? "?")")
    }

    @objc private func resumeDimming() {
        Settings.pausedUntil = nil
        Log.write("dim", "resumed")
    }

    @objc private func toggleSoundbar() { Settings.sbEnabled.toggle() }

    private func showLevel(_ level: Int?) {
        guard let slider = levelSlider, let level else { return }
        // Don't pull the knob out from under a drag.
        if NSEvent.pressedMouseButtons & 1 == 0 { slider.integerValue = level }
        levelLabel?.stringValue = "\(level)"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        levelLabel?.stringValue = "\(sender.integerValue)"
        Soundbar.shared.controller.setLevel(sender.integerValue)
    }

    /// Asks macOS for Accessibility access. The request is what adds Tide to the list in System Settings
    /// (opening the pane alone doesn't), and the system dialog it shows links to the pane.
    @objc func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { return }
        NSApp.activate(ignoringOtherApps: true)
        let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("app", "launch at login change failed: \(error)")
            let a = NSAlert(error: error)
            a.messageText = "Couldn't change Launch at Login"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(dimmer: dimmer, app: self)
            settingsWindow?.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Free the window and its SwiftUI views on close; it's rebuilt on next open.
    func windowWillClose(_ note: Notification) {
        guard (note.object as? NSWindow) === settingsWindow else { return }
        DispatchQueue.main.async { self.settingsWindow = nil }
    }
}
