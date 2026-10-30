import AppKit
import NotchKit

/// Quits DynamicNotch without asking: for quitting itself (installing an update, a second
/// copy stepping aside, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = HubStore()
    private let media = NowPlaying()
    private let volume = VolumeController()
    private var server: SocketServer?
    private var notch: NotchScreens?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)

        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu, where Mac apps keep it.
        mainMenu.items.first?.submenu?.insertItem(item("Check for Updates…", #selector(checkForUpdates)), at: 1)
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 2)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("\(AppInfo.name) Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
        AppAppearance.start()
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before the socket, the notch or sync starts.
        if let snapshot = ProcessInfo.processInfo.environment["DYNAMICNOTCH_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: self)
            return
        }
        if let how = ProcessInfo.processInfo.environment["DYNAMICNOTCH_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        #endif

        let server = SocketServer(path: NotchPaths.socketPath) { [store] request, conn in store.handle(request, conn) }
        do {
            guard try server.start() else {
                NSLog("DynamicNotch is already running; quitting.")
                QuitConfirmation.quitNow()
                return
            }
        } catch {
            NSLog("DynamicNotch: couldn't open socket: \(error)")
        }
        self.server = server

        let notch = NotchScreens(store: store, media: media, volume: volume)
        self.notch = notch
        notch.onOpenSettings = { [weak self] in self?.showSettings() }
        SettingsWindow.shared.showNotch = { [weak notch] in notch?.show() }

        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        UserDefaults.standard.set(true, forKey: "launchedBefore")

        setUpStatusItem()
        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in self?.statusItem?.button?.image })

        // Restarting drops a permission waiting in the notch and running activities' progress.
        AutoUpdater.shared.busyCheck = { [weak self] in
            guard let self else { return nil }
            if !store.permissions.isEmpty { return "a permission is waiting for an answer" }
            if store.runningCount > 0 { return "something is running" }
            if notch.isExpanded { return "the notch is open" }
            return nil
        }
        AutoUpdater.shared.start()
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { showSettings() }
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when DynamicNotch quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard Preferences.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "The notch and its live activities stop until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { Preferences.shared.confirmQuit = false }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Show Notch", #selector(toggleNotch)), at: 0)
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `dynamicnotch://` URLs, from ToolHUD, Shortcuts or a script.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "dynamicnotch" {
            switch url.host {
            case "show": notch?.show()
            case "clear": store.clearFinished()
            default: showSettings()
            }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: AppInfo.name)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = MenuHub.shared.showsOwnIcon
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(notch?.isExpanded == true ? "Hide Notch" : "Show Notch", #selector(toggleNotch)))
        menu.addItem(item("Clear Finished Activities", #selector(clearFinished)))

        menu.addItem(.separator())
        let helpEntry = item("\(AppInfo.name) Help", #selector(showHelp))
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc func toggleNotch() { notch?.toggle() }
    @objc func clearFinished() { store.clearFinished() }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

// Top-level code isn't main-actor isolated in Swift 5 mode, though it runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}
