#if DEBUG
import AppKit

/// Debug builds only. `DYNAMICNOTCH_DEBUG_UPDATE_NOTES=<folder>`: fetches the notes of
/// DynamicNotch's own releases, draws the update prompt, the What's New sheet Settings shows
/// after an automatic update, and Settings itself to PNGs, writes report.txt, and quits. It
/// starts nothing else: no socket, notch, sync or updater. DynamicNotch keeps its settings in
/// the standard defaults, so run it under a test bundle identifier, never the real one.
@MainActor
enum DebugUpdateNotes {
    static func run(folder: String) {
        guard Bundle.main.bundleIdentifier != "com.smanke.DynamicNotch" else {
            NSLog("DynamicNotch: run the update-notes test under a test bundle identifier")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        func contentSize() -> CGSize {
            SettingsWindow.shared.debugWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }
        func select(_ index: Int) {
            (SettingsWindow.shared.debugWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = index
        }

        Task {
            note("running \(AppInfo.version) as \(Bundle.main.bundleIdentifier ?? "?")")
            // The update prompt, as someone on 0.1.2 would see it offered 0.1.4.
            let notes = await ReleaseNotes.fetch(newAfter: "0.1.2", through: "0.1.4")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "0.1.4", current: "0.1.2", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            render(alert.window, to: out.appendingPathComponent("update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "0.1.4"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            SettingsTabs.chosenSize = nil
            SettingsWindow.shared.show()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appendingPathComponent("whats-new.png"))
            note("sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            render(SettingsWindow.shared.debugWindow, to: out.appendingPathComponent("general.png"))
            let window = SettingsWindow.shared.debugWindow
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) general content \(contentSize())")

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            SettingsWindow.shared.showWhatsNew()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appendingPathComponent("whats-new-asked.png"))
            note("asked sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Each pane opens at its own height until the user drags a size, then every pane uses that.
            select(1)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            note("notch natural content \(contentSize())")
            SettingsTabs.chosenSize = NSSize(width: 680, height: 420)
            select(0)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            render(SettingsWindow.shared.debugWindow, to: out.appendingPathComponent("general-dragged.png"))
            note("general after a chosen 680x420: \(contentSize())")
            SettingsTabs.chosenSize = nil
            note("done")
            exit(0)
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
