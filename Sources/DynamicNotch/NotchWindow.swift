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

/// Owns the transparent panel over the notch and decides when it's expanded.
final class NotchWindowController {
    private let panel: NotchPanel
    let geometry = NotchGeometry()
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    private var hovering = false
    private var peekUntil = Date.distantPast
    private var pendingHover: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var pollTimer: Timer?

    /// The panel is a fixed, mostly transparent canvas; SwiftUI animates the shape inside it.
    private let canvas = CGSize(width: 760, height: 640)

    init(store: HubStore, media: NowPlaying, volume: VolumeController) {
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

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(m)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.position() }

        store.onPeek = { [weak self] seconds in self?.peek(for: seconds) }
    }

    // MARK: Placement

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func position() {
        guard let screen = Self.targetScreen() else { return }
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

    private func peek(for seconds: TimeInterval) {
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
