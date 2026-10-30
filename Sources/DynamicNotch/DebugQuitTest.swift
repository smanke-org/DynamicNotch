#if DEBUG
import AppKit

/// `DYNAMICNOTCH_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` (trace to
/// `DYNAMICNOTCH_DEBUG_TRACE`): quits as ⌘Q does, then answers the question a second
/// later: presses Return, clicks Cancel or Quit (ticking "Don't ask again" first for
/// `suppress`), or with `off` turns the setting off first. What the question looked like
/// is traced before any answer; if the app is still running afterwards, so is that.
@MainActor
enum DebugQuitTest {
    private static var lines: [String] = []

    private static func trace(_ s: String) {
        lines.append(s)
        if let tracePath = ProcessInfo.processInfo.environment["DYNAMICNOTCH_DEBUG_TRACE"] {
            try? lines.joined(separator: "\n").appending("\n").write(toFile: tracePath, atomically: true, encoding: .utf8)
        }
    }

    static func run(_ how: String) {
        trace("started \(AppInfo.displayVersion) confirmQuit \(Preferences.shared.confirmQuit) policy \(NSApp.activationPolicy().rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if how == "off" { Preferences.shared.confirmQuit = false }
                trace("no question")
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        trace(asked())
                        answerQuestion(how)
                    }
                }
                RunLoop.main.add(answer, forMode: .common)
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        trace("still running; confirmQuit \(Preferences.shared.confirmQuit); policy \(NSApp.activationPolicy().rawValue)")
                    }
                }
            }
        }
    }

    private static var buttons: [NSButton] = []

    /// What the question shows, and whether it's in front.
    private static func asked() -> String {
        guard let window = NSApp.modalWindow else { return "no modal" }
        var texts: [String] = []
        buttons = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        return "asked \(texts) buttons \(titles) key \(window.isKeyWindow) active \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)"
    }

    private static func answerQuestion(_ how: String) {
        guard let window = NSApp.modalWindow else { return }
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }
}
#endif
