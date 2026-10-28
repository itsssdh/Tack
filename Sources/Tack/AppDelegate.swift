import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    var settingsFrame: NSRect? { settingsWindow?.frame }
    var settingsIsInFront: Bool { settingsWindow?.isVisible == true && NSApp.isActive && settingsWindow?.isKeyWindow == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Prefs.applyAppearance()
        installMainMenu()

        if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), i + 1 < CommandLine.arguments.count {
            do {
                try AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                exit(0)
            } catch {
                print("Could not write the icon: \(error)")
                exit(1)
            }
        }

        #if FRAMEGRAB_TESTING
        // Test builds only (see build_app.sh): the self-test and its helpers are not part of the shipped app.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        RecordingController.shared.onStateChange = { [weak self] in self?.updateStatusIcon() }
        HotkeyManager.shared.onAction = { [weak self] action in self?.perform(action) }
        HotkeyManager.shared.registerAll()

        // Launch at login is on by default; this runs once, so turning it off in Settings is respected afterwards.
        if !UserDefaults.standard.bool(forKey: "didSetLaunchAtLoginDefault") {
            UserDefaults.standard.set(true, forKey: "didSetLaunchAtLoginDefault")
            try? SMAppService.mainApp.register()
        }

        // Build the Settings window now, hidden, so the first time it opens it is already laid out instead of building as it appears.
        DispatchQueue.main.async { [weak self] in self?.prepareSettings() }

        #if FRAMEGRAB_TESTING
        if CommandLine.arguments.contains("--show-takeover-prompt") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.askToReplaceAppleShortcuts(apply: false) }
        }
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showSettings() }
        }
        #endif

        // First launch only: offer to take over macOS's screenshot shortcuts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.offerScreenshotTakeover() }
    }

    /// Asked once, the first time Tack ever runs, and only if Apple's screenshot shortcuts are still on.
    /// Existing users (who already have a capture history) are not asked; they can use the button in Settings > Shortcuts.
    private func offerScreenshotTakeover() {
        let key = "askedToReplaceAppleScreenshots"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        let isExistingUser = FileManager.default.fileExists(atPath: AppFolders.supportFolder.appendingPathComponent("history.json").path)
        defaults.set(true, forKey: key)
        guard !isExistingUser, NativeScreenshots.anyEnabled else { return }
        askToReplaceAppleShortcuts(apply: true)
    }

    /// The question itself. `apply: false` is for photographing it without changing anything.
    private func askToReplaceAppleShortcuts(apply: Bool) {
        let alert = NSAlert()
        alert.messageText = "Use Tack for your screenshots?"
        alert.informativeText = "macOS already uses ⇧⌘3, ⇧⌘4 and ⇧⌘5 for its own screenshots. Tack can turn those off and answer them itself, with previews, markup and recording. This changes a keyboard setting on your Mac; you can undo it any time in Tack Settings > Shortcuts."
        alert.addButton(withTitle: "Use Tack")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, apply else { return }
        if let error = NativeScreenshots.replaceWithTack() {
            Alerts.show(title: "Could not switch the shortcuts", message: error + " You can try again in Settings > Shortcuts.")
        }
    }

    private func updateStatusIcon() {
        let recording = RecordingController.shared.isRecording
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "viewfinder", accessibilityDescription: "Tack")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .light))
        image?.isTemplate = !recording
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Not visible (this is a menu bar app) but makes Cut / Copy / Paste / Select All work in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AboutInfo.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AboutInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Without these, ⌘W and ⌘M do nothing in Settings, the editors, History and the Recognized Text window.
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: CaptureService.shared.captureArea()
        case .captureWindow: CaptureService.shared.captureWindow()
        case .captureFullscreen: CaptureService.shared.captureFullscreen()
        case .capturePrevious: CaptureService.shared.capturePreviousArea()
        case .captureText: CaptureService.shared.captureText()
        case .capturePinned: CaptureService.shared.capturePinned()
        case .recordScreen: RecordingController.shared.toggle()
        case .openEditor: Editor.openFromAnywhere()
        case .showHistory: HistoryWindow.show()
        case .openSettings: showSettings()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addAction(.captureArea, to: menu, title: "Area")
        addAction(.captureWindow, to: menu, title: "Window")
        addAction(.captureFullscreen, to: menu, title: "Fullscreen")
        menu.addItem(.separator())

        let recording = RecordingController.shared.isRecording
        addAction(.recordScreen, to: menu, title: recording ? "Stop Recording" : "Record Screen…")
        menu.addItem(.separator())

        // Recent
        let historyItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let recent = History.shared.recent(8)
        if recent.isEmpty {
            let none = NSMenuItem(title: "Nothing saved yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for item in recent {
            let m = NSMenuItem(title: item.url.lastPathComponent, action: #selector(openHistoryFile(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = item.path
            sub.addItem(m)
        }
        sub.addItem(.separator())
        addAction(.showHistory, to: sub, title: "Show All…")
        historyItem.submenu = sub
        menu.addItem(historyItem)

        // Only shown when needed to undo something: locked pins ignore the mouse, and hidden desktop icons are otherwise stuck.
        var recovery: [NSMenuItem] = []
        if PinManager.shared.anyLocked {
            let unlock = NSMenuItem(title: "Unlock Pinned Screenshots", action: #selector(unlockPins), keyEquivalent: "")
            unlock.target = self
            recovery.append(unlock)
        }
        if DesktopIcons.hidden {
            let icons = NSMenuItem(title: "Show Desktop Icons", action: #selector(toggleDesktopIcons), keyEquivalent: "")
            icons.target = self
            recovery.append(icons)
        }
        if !recovery.isEmpty {
            menu.addItem(.separator())
            recovery.forEach { menu.addItem($0) }
        }

        menu.addItem(.separator())
        addAction(.openSettings, to: menu, title: "Settings…")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addAction(_ action: HotkeyAction, to menu: NSMenu, title: String? = nil) {
        let item = NSMenuItem(title: title ?? action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        let shortcut = HotkeyManager.shared.shortcut(for: action)
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.menuModifierMask
        menu.addItem(item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        // Let the menu finish closing before the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.perform(action)
        }
    }

    @objc private func openHistoryFile(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    @objc private func unlockPins() { PinManager.shared.unlockAll() }

    @objc private func toggleDesktopIcons() {
        DesktopIcons.set(hidden: !DesktopIcons.hidden)
    }

    // MARK: Settings window

    private func prepareSettings() {
        guard settingsWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tack Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // the pane header carries the title
        window.toolbarStyle = .unified
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [] // the window keeps its size; the content never resizes it
        window.contentViewController = hosting
        // With no automatic sizing the hosting view starts empty, so give the window its size explicitly.
        window.setContentSize(NSSize(width: 800, height: 600))
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false // a real window: it stays put when you click elsewhere
        window.delegate = self
        window.center()
        hosting.view.layoutSubtreeIfNeeded()
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        DockPresence.settingsOpen = false
        DockPresence.refresh()
    }

    func showSettings() {
        prepareSettings()
        // While Settings is open Tack shows in the Dock, like the editors, so the window is easy to get back to.
        if settingsWindow?.isVisible != true { settingsWindow?.centerOnPointerScreen() }
        DockPresence.settingsOpen = true
        DockPresence.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Hides the icons on the desktop (handy for clean screenshots) by asking Finder not to draw them.
enum DesktopIcons {
    static var hidden: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["read", "com.apple.finder", "CreateDesktop"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "0" || out == "false"
    }

    static func set(hidden: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        run("/usr/bin/killall", ["Finder"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}
