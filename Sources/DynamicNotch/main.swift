import AppKit
import NotchKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = HubStore()
    private let media = NowPlaying()
    private let volume = VolumeController()
    private var server: SocketServer?
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)

        let server = SocketServer(path: NotchPaths.socketPath) { [store] request, conn in store.handle(request, conn) }
        do {
            guard try server.start() else {
                NSLog("DynamicNotch is already running; quitting.")
                NSApp.terminate(nil)
                return
            }
        } catch {
            NSLog("DynamicNotch: couldn't open socket: \(error)")
        }
        self.server = server

        notch = NotchWindowController(store: store, media: media, volume: volume)
        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "DynamicNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Notch", action: #selector(toggleNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Finished Activities", action: #selector(clearFinished), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DynamicNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() { notch?.toggle() }

    @objc private func clearFinished() { store.clearFinished() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("DynamicNotch: login item change failed: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
