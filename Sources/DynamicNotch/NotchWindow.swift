import AppKit
import SwiftUI

/// Shared layout state between the AppKit window controller and the SwiftUI views.
final class NotchGeometry: ObservableObject {
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasNotch = false
    @Published var expanded = false
    /// Measured size of the drawn black shape (collapsed or expanded).
    var contentSize = CGSize(width: 190, height: 32)

    var earWidth: CGFloat { (notchSize.height * 1.15).rounded() }
    var expandedWidth: CGFloat { max(470, notchSize.width + 120) }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons should work on the first click even though the panel never activates the app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The notch on every display the user chose: one `NotchWindowController` per screen, all
/// showing the same activities. Rebuilt when displays come and go or the choice changes.
@MainActor
final class NotchScreens {
    private let store: HubStore
    private let media: NowPlaying
    private let volume: VolumeController
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Called on a right-click or ⌘-click on the notch.
    var onOpenSettings: (() -> Void)?

    init(store: HubStore, media: NowPlaying, volume: VolumeController) {
        self.store = store
        self.media = media
        self.volume = volume
        rebuild()
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification, Preferences.displaysDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.rebuild() }
            })
        }
        store.onPeek = { [weak self] seconds in
            MainActor.assumeIsolated { self?.controllers.values.forEach { $0.peek(for: seconds) } }
        }
    }

    /// The screens the notch belongs on: every one, or just the one with the notch (else the
    /// built-in display, else the main one).
    static func targetScreens(_ choice: NotchDisplays) -> [NSScreen] {
        if choice == .all { return NSScreen.screens }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
            ?? NSScreen.screens.first
        return screen.map { [$0] } ?? []
    }

    private func rebuild() {
        let wanted = Dictionary(Self.targetScreens(Preferences.shared.notchDisplays).map { ($0.displayID, $0) },
                                uniquingKeysWith: { first, _ in first })
        for (id, controller) in controllers where wanted[id] == nil {
            controller.close()
            controllers[id] = nil
        }
        for id in wanted.keys where controllers[id] == nil {
            let controller = NotchWindowController(displayID: id, store: store, media: media, volume: volume)
            controller.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
            controllers[id] = controller
        }
    }

    var isExpanded: Bool { controllers.values.contains { $0.isExpanded } }

    /// Opens every notch for a few seconds (dynamicnotch://show, the Settings preview).
    func show() { controllers.values.forEach { $0.show() } }

    /// Menu-bar "Show" item: closes them all if any is open, otherwise opens them all.
    func toggle() {
        if isExpanded {
            controllers.values.forEach { if $0.isExpanded { $0.toggle() } }
        } else {
            show()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Owns the transparent panel over one screen's notch and decides when it's expanded.
final class NotchWindowController {
    private let panel: NotchPanel
    let geometry = NotchGeometry()
    private let displayID: CGDirectDisplayID
    private let store: HubStore
    private let media: NowPlaying
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    var onOpenSettings: (() -> Void)?

    private var hovering = false
    private var peekUntil = Date.distantPast
    private var pendingHover: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var pollTimer: Timer?

    /// The panel is a fixed, mostly transparent canvas; SwiftUI animates the shape inside it.
    private let canvas = CGSize(width: 760, height: 640)

    init(displayID: CGDirectDisplayID, store: HubStore, media: NowPlaying, volume: VolumeController) {
        self.displayID = displayID
        self.store = store
        self.media = media
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let root = NotchRootView(geometry: geometry, store: store, media: media, volume: volume)
        panel.contentView = FirstMouseHostingView(rootView: root)

        position()
        panel.orderFrontRegardless()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            if self?.openSettingsIfAsked(e) != true { self?.mouseMoved() }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            // Taken here, so the ⌘-click doesn't also press whatever is under it.
            if self?.openSettingsIfAsked(e) == true { return nil }
            self?.mouseMoved()
            return e
        }) {
            monitors.append(m)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.position() }
    }

    /// Takes the panel and its event monitors down, when its screen goes or isn't wanted.
    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        screenObserver.map(NotificationCenter.default.removeObserver)
        pendingHover?.cancel()
        pendingCollapse?.cancel()
        pollTimer?.invalidate()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Placement

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    private func position() {
        guard let screen else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            geometry.notchSize = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
            geometry.hasNotch = true
        } else {
            // No notch: a pill in the middle of the menu bar.
            let menuBar = f.maxY - screen.visibleFrame.maxY
            geometry.notchSize = CGSize(width: 190, height: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
            geometry.hasNotch = false
        }
        panel.setFrame(NSRect(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height,
                              width: canvas.width, height: canvas.height), display: true)
    }

    /// Screen-space rect of what's drawn right now (top-centered in the panel).
    /// While expanded it never shrinks below the expanded width or the notch's own hover zone,
    /// so a stale or mid-animation measurement can't make the mouse look "outside" and cause a collapse/expand loop.
    private func drawnRect() -> NSRect {
        let f = panel.frame
        var s = geometry.contentSize
        if geometry.expanded {
            s.width = max(s.width, geometry.expandedWidth)
            s.height = max(s.height, geometry.notchSize.height + 60)
        }
        let rect = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
        return geometry.expanded ? rect.union(hoverZone()) : rect
    }

    /// Generous hover target around the collapsed notch, including where the ears go.
    private func hoverZone() -> NSRect {
        let f = panel.frame
        let w = geometry.notchSize.width + geometry.earWidth * 2 + 16
        let h = geometry.notchSize.height + 4
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    // MARK: Settings shortcut

    /// A right-click or ⌘-click on the notch (open or closed) opens Settings. Only where the
    /// notch is actually drawn: an empty, hidden pill leaves the menu bar's clicks alone.
    private func openSettingsIfAsked(_ event: NSEvent) -> Bool {
        let asked = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.command))
        guard asked else { return false }
        let shown = geometry.hasNotch || geometry.expanded || Ears(store: store, media: media).hasContent
        let zone = geometry.expanded ? drawnRect() : hoverZone()
        guard shown, zone.contains(NSEvent.mouseLocation) else { return false }
        onOpenSettings?()
        return true
    }

    // MARK: Expand / collapse

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let overContent = geometry.expanded && drawnRect().insetBy(dx: -2, dy: -2).contains(p)
        // Only take clicks where something is actually drawn; elsewhere stay click-through.
        panel.ignoresMouseEvents = !overContent

        let inside = geometry.expanded ? drawnRect().insetBy(dx: -10, dy: -10).contains(p) : hoverZone().contains(p)
        if inside, !hovering {
            hovering = true
            pendingCollapse?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering else { return }
                self.setExpanded(true)
            }
            pendingHover = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (geometry.expanded ? 0 : 0.12), execute: work)
        } else if !inside, hovering {
            hovering = false
            pendingHover?.cancel()
            scheduleCollapse(after: 0.35)
        }
    }

    func peek(for seconds: TimeInterval) {
        peekUntil = max(peekUntil, Date().addingTimeInterval(seconds))
        setExpanded(true)
        scheduleCollapse(after: seconds)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        pendingCollapse?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            let remaining = self.peekUntil.timeIntervalSinceNow
            if remaining > 0 { return self.scheduleCollapse(after: remaining + 0.05) }
            self.setExpanded(false)
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        guard geometry.expanded != value else { return }
        geometry.expanded = value
        if value {
            // Belt and braces: mouse-moved events can be missed while the cursor is over our own panel,
            // so poll while expanded to be sure we notice the mouse leaving.
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.mouseMoved() }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            panel.ignoresMouseEvents = true
        }
        // Re-evaluate hit testing once the new layout has been measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.mouseMoved() }
    }

    var isExpanded: Bool { geometry.expanded }

    /// Opens the notch for a few seconds (dynamicnotch://show, the Settings preview).
    func show() { peek(for: 6) }

    /// Menu-bar "Show" item / testing.
    func toggle() {
        if geometry.expanded {
            peekUntil = .distantPast
            setExpanded(false)
        } else {
            peek(for: 6)
        }
    }
}
