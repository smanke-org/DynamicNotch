import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// Kept for the shared Help views: DynamicNotch has no shortcuts of its own to fill in.
    static func resolve(_ text: String) -> String { text }

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Notch": "notch"
        default: "sync"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("DynamicNotch turns your Mac's notch into a status area: live progress from any script or shell command, your Claude Code sessions (with Allow and Deny right in the notch), the music that's playing, and the volume."),
            .text("Move the pointer onto the notch to open it, and away to close it. When something needs you, such as a permission request from Claude Code, it opens by itself."),
            .heading("The two sides of the notch"),
            .keys([
                ("Left", "Album art while music plays; an orange hand when something needs you"),
                ("Right", "A spinner while things run (with a count), then a green check or red cross when the last one finishes"),
            ]),
            .text("On a Mac without a notch, or on an external display, DynamicNotch shows a pill in the middle of the menu bar, only while there's something to show."),
            .tip("The menu bar icon's Show Notch opens it for a few seconds, handy on a screen where you can't hover the notch."),
            .tip("Right-click or ⌘-click the notch, open or closed, to open Settings."),
            .tip("While ToolHUD is running, DynamicNotch's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings › General."),
            .tip("Quitting asks first, since the notch and its live activities stop while DynamicNotch is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "notch", title: "The Notch", symbol: "rectangle.topthird.inset.filled", blocks: [
            .text("Choose how the notch opens and closes, and which displays show it, in Settings › Notch."),
            .keys([
                ("Grow", "The notch stretches open with a little bounce, the album art slides from the side of the notch into the music card, and each row comes into focus in turn"),
                ("Fade", "The open notch fades in at full size, without moving"),
            ]),
            .text("Show Notch, under Preview, opens it so you can see the one you picked."),
            .tip("With Reduce Motion on in System Settings › Accessibility › Display, the notch always fades."),
            .heading("Events"),
            .keys([
                ("Orange glow", "Something needs you: a permission request, or a Claude Code session waiting for you. The edge of the notch flashes orange"),
                ("Shake", "An activity failed. The notch shakes sideways for a moment"),
                ("Green ripple", "An activity succeeded. Rings spread out from its check mark"),
            ]),
            .heading("Displays"),
            .keys([
                ("The built-in display", "The notch shows only on the display with the notch (on a Mac without one, the main display)"),
                ("Every display", "Each display gets its own notch, or a pill in the middle of its menu bar, showing the same activities"),
            ]),
        ]),

        HelpTopic(id: "activities", title: "Live Activities", symbol: "gearshape.2", blocks: [
            .text("The notch command sends progress to the notch from any script or Terminal window. It comes inside the app. To use it in Terminal, link it once: ln -sf /Applications/DynamicNotch.app/Contents/MacOS/notch ~/.local/bin/notch"),
            .heading("Commands"),
            .keys([
                ("notch start <title>", "Show an activity; add --progress 40%, --detail, --url or --symbol"),
                ("notch update <id>", "Change its --progress or --detail"),
                ("notch done <title>", "Finish it with a green check"),
                ("notch fail <title>", "Finish it with a red cross"),
                ("notch run -- <cmd>", "Run any command as an activity; reads %, [3/10] and ffmpeg's time= for progress"),
                ("notch ci <PR>", "Follow a pull request's checks (needs gh)"),
                ("notch list", "What the notch is showing"),
                ("notch clear", "Clear finished activities"),
            ]),
            .text("Finished activities stay for a while (failures longer), and you can dismiss one with its ✕. Clicking an activity with a --url opens it."),
            .heading("Every long shell command"),
            .text("Add eval \"$(notch shell-init zsh)\" to ~/.zshrc. Commands that run longer than NOTCH_SHOW_AFTER seconds (10 unless you set it) appear in the notch and turn green or red when they end. Interactive tools such as vim, ssh, less and claude are skipped; change the list with NOTCH_IGNORE."),
        ]),

        HelpTopic(id: "claude", title: "Claude Code", symbol: "hand.raised", blocks: [
            .keys([
                ("notch setup claude", "Add DynamicNotch's hooks to ~/.claude/settings.json (it's backed up first)"),
                ("notch setup claude --print", "Only print the hooks"),
                ("notch setup claude --remove", "Take them out again"),
            ]),
            .text("Each session shows as Working, Needs you or Idle. When Claude asks for a permission, the notch opens with Allow, Deny and Answer in terminal."),
            .text("If you don't answer within NOTCH_APPROVAL_TIMEOUT seconds (120 unless you set it), or DynamicNotch isn't running, Claude Code asks in the terminal as usual."),
        ]),

        HelpTopic(id: "media", title: "Music and Volume", symbol: "music.note", blocks: [
            .text("Music and Spotify show what's playing, with play, pause and skip. macOS asks once per player for permission to control it. Click the album art to bring the player forward."),
            .text("Drag the volume slider to change the current output's volume, or click its speaker to mute. It follows the keyboard's volume keys too."),
            .tip("Other players, such as web browsers, can't be shown: macOS keeps its Now Playing information to Apple's own apps."),
        ]),

        HelpTopic(id: "sync", title: "Sync and Updates", symbol: "icloud", blocks: [
            .text("Show in Dock and Show in menu bar choose where DynamicNotch appears; the notch shows either way. With both off, open DynamicNotch again from Applications or Spotlight to get back to Settings."),
            .text("Turn on \"Sync settings with your other Macs\" in Settings › General to share the animation, appearance, update choice, asking before quitting and where DynamicNotch appears through iCloud Drive. Open at login stays separate on each Mac."),
            .heading("Updates"),
            .keys([
                ("Install automatically", "Download, check and install new versions when nothing is running or waiting in the notch and the Mac isn't in use"),
                ("Ask me first", "Send a notification and wait for you"),
                ("Don't check", "Only check when you choose Check for Updates"),
            ]),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "link", blocks: [
            .keys([
                ("dynamicnotch://show", "Open the notch for a few seconds"),
                ("dynamicnotch://clear", "Clear finished activities"),
                ("dynamicnotch://settings", "Open Settings"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's DynamicNotch buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("notch says DynamicNotch isn't running"),
            .text("Open DynamicNotch. The command talks to the app over a socket in ~/Library/Application Support/DynamicNotch."),
            .heading("Play and pause do nothing"),
            .text("Allow DynamicNotch to control Music or Spotify in System Settings › Privacy & Security › Automation."),
            .heading("The notch won't open"),
            .text("Hover right on the notch, or choose Show Notch from the menu bar icon. On a Mac without a notch the pill only appears while something is running, playing or waiting."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DynamicNotchHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
