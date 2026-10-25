import AppKit
import SwiftUI

/// Settings in an AppKit window with the standard toolbar tabs (an icon above each
/// label), so the Dock menu and the menu bar item can open it (SwiftUI's Settings
/// scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    /// Opens the notch for a moment, to try the animation; set by the app delegate.
    var showNotch: (() -> Void)?

    func show() {
        if window == nil {
            let tabs = SettingsTabs()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("Notch", "rectangle.topthird.inset.filled", NotchSettings())
        add("General", "gearshape", GeneralSettings())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ title: String, _ symbol: String, _ view: some View) {
        let pane = VStack(spacing: 0) {
            view
            // The version in the middle, the round Help button in the corner, as macOS does.
            ZStack {
                Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    HelpButton(topic: Help.topic(forSettingsTab: title)).fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(width: 520)
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingController(rootView: pane.frame(maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        item.viewController?.preferredContentSize = NSSize(width: 520, height: min(height, available))
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { fit(tabViewItem) }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectionChanged()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged()
    }

    private func selectionChanged() {
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }
}

// MARK: - Notch

struct NotchSettings: View {
    @State private var prefs = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                Picker("Open and close by", selection: $prefs.openAnimation) {
                    ForEach(NotchAnimation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(prefs.openAnimation.detail).font(.callout).foregroundStyle(.secondary)
                LabeledContent("Preview") {
                    Button("Show Notch") { SettingsWindow.shared.showNotch?() }
                }
            } header: {
                Text("Animation")
            } footer: {
                Text(reduceMotion
                     ? "Reduce Motion is on in System Settings › Accessibility › Display, so the notch fades whichever you choose."
                     : "With Reduce Motion on in System Settings › Accessibility › Display, the notch always fades.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Show the notch on", selection: $prefs.notchDisplays) {
                    ForEach(NotchDisplays.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Displays")
            } footer: {
                Text("A display without a notch shows a pill in the middle of its menu bar while there's something to show. Without a built-in display, \"The built-in display\" means the main one. Right-click or ⌘-click the notch to open these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared
    @State private var login = LaunchAtLogin.shared
    @State private var sync = SettingsSync.shared
    @State private var updater = AutoUpdater.shared

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            "DynamicNotch checks \(updater.interval.phrase). A new version installs itself when nothing is running or waiting for you in the notch, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "DynamicNotch checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "DynamicNotch won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        Form {
            AppearanceSection(appName: "DynamicNotch") { SettingsSync.shared.localDidChange() }
            Section {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows this menu as a submenu of its own, and DynamicNotch’s icon leaves the menu bar until ToolHUD quits.")
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "DynamicNotch", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Where DynamicNotch appears")
            } footer: {
                Text("The notch itself shows either way.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open DynamicNotch at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    LabeledContent {
                        Button("Sync Now") { sync.syncNow() }
                    } label: {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                        } else {
                            Text("Waiting for iCloud Drive…")
                        }
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("The animation, appearance, update choice and where DynamicNotch appears follow you to every Mac signed in to the same iCloud account with sync turned on. Open at login stays separate on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for DynamicNotch, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateFooter).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh(); updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        MenuHub.shared.reload()
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
