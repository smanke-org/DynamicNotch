import AppKit
import Foundation
import NotchKit

/// What the agent commands work on, set by the app delegate once it has made them. In a Debug
/// test copy only `store` is set: no notch on screen, no music or volume observers.
@MainActor
enum AgentApp {
    static var store: HubStore?
    static var notch: NotchScreens?
    static var media: NowPlaying?
    static var volume: VolumeController?

    static func hub() throws -> HubStore {
        guard let store else { throw AgentError.unavailable("DynamicNotch is still starting. Try again in a moment") }
        return store
    }
}

/// Every command the CLI and the MCP server offer. Each `run` calls the same code as the
/// notch, its menu and Settings. The list itself isn't main-actor bound, so the CLI and the MCP
/// server can read it; every `run`, and the helpers below, run on the main actor in the app.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(
            name: "status",
            summary: "What DynamicNotch is showing: counts of activities, Claude Code sessions and waiting permissions, the music playing, the volume.",
            example: "notch status --json",
            readOnly: true
        ) { _ in try status() },

        AgentCommand(
            name: "activities list",
            summary: "The live activities in the notch, newest last, with state, progress and detail.",
            params: [.init(name: "all", kind: .boolean, help: "also list activities still waiting out their --show-after delay")],
            example: "notch activities list --json",
            readOnly: true
        ) { args in
            let store = try AgentApp.hub()
            let all = try args.bool("all") == true
            let items = store.activities.filter { all || $0.visible }.map(activityJSON)
            return ["activities": items, "total": items.count]
        },

        AgentCommand(
            name: "activities start",
            summary: "Show a running activity in the notch, with optional progress, like `notch start` in a script.",
            params: [
                .init(name: "title", required: true, positional: true, help: "what is running, like \"Deploy\""),
                .init(name: "id", help: "id to update it by later (default: the title in lowercase with dashes)"),
                .init(name: "detail", help: "a second line, like \"Uploading\""),
                .init(name: "progress", help: "40%, 40 or 0.4; leave out for a spinner"),
                .init(name: "symbol", help: "SF Symbol name for its icon"),
                .init(name: "url", help: "opened when the row is clicked"),
            ],
            example: "notch activities start \"Deploy\" --progress 40% --detail \"Uploading\""
        ) { args in
            let store = try AgentApp.hub()
            let title = try args.required("title")
            var message = ActivityMessage(id: args.string("id") ?? slug(title))
            message.title = title
            message.detail = args.string("detail")
            message.progress = try progress(args.string("progress"))
            message.symbol = args.string("symbol")
            message.url = args.string("url")
            message.source = "agent"
            message.state = .running
            message.startedAt = Date()
            store.apply(message)
            return try shown(message.id, in: store)
        },

        AgentCommand(
            name: "activities update",
            summary: "Change an activity's progress, detail or title, or finish it (state success or failure: a green check, or a red cross and a shake).",
            params: [
                .init(name: "id", required: true, positional: true, help: "the activity's id, from `notch activities list`"),
                .init(name: "title", help: "new title"),
                .init(name: "detail", help: "new second line"),
                .init(name: "progress", help: "40%, 40 or 0.4; \"none\" for a spinner"),
                .init(name: "state", help: "running, success or failure"),
            ],
            example: "notch activities update deploy --progress 80%"
        ) { args in
            let store = try AgentApp.hub()
            let id = try args.required("id")
            guard store.activities.contains(where: { $0.id == id }) else {
                throw AgentError.notFound("no activity with id \"\(id)\". Run `notch activities list --all`")
            }
            var message = ActivityMessage(id: id)
            message.title = args.string("title")
            message.detail = args.string("detail")
            if let raw = args.string("progress") {
                message.progress = raw.lowercased() == "none" ? -1 : try progress(raw)
            }
            if let raw = args.string("state") {
                guard let state = ActivityState(rawValue: raw.lowercased()) else {
                    throw AgentError.usage("--state must be running, success or failure, not \"\(raw)\"")
                }
                message.state = state
            }
            store.apply(message)
            return try shown(id, in: store)
        },

        AgentCommand(
            name: "activities remove",
            summary: "Take one activity out of the notch, like its ✕ button.",
            params: [.init(name: "id", required: true, positional: true, help: "the activity's id, from `notch activities list`")],
            example: "notch activities remove deploy"
        ) { args in
            let store = try AgentApp.hub()
            let id = try args.required("id")
            guard let activity = store.activities.first(where: { $0.id == id }) else {
                throw AgentError.notFound("no activity with id \"\(id)\". Run `notch activities list --all`")
            }
            store.dismiss(activity)
            return ["removed": id]
        },

        AgentCommand(
            name: "activities clear",
            summary: "Remove the finished activities (Clear Finished Activities in the menu). Running ones stay.",
            example: "notch activities clear"
        ) { _ in
            let store = try AgentApp.hub()
            let finished = store.activities.filter { $0.state != .running }.count
            store.clearFinished()
            return ["cleared": finished]
        },

        AgentCommand(
            name: "notice show",
            summary: "Show a one-off notice in the notch: a green check with a ripple, or with --failed a red cross and a shake. It goes away on its own.",
            params: [
                .init(name: "title", required: true, positional: true, help: "the notice, like \"Tests passed\""),
                .init(name: "detail", help: "a second line"),
                .init(name: "failed", kind: .boolean, help: "show it as a failure"),
                .init(name: "id", help: "finishes the running activity with this id instead of adding a new row"),
                .init(name: "url", help: "opened when the row is clicked"),
            ],
            example: "notch notice show \"Tests passed\" --detail \"128 tests\""
        ) { args in
            let store = try AgentApp.hub()
            let title = try args.required("title")
            var message = ActivityMessage(id: args.string("id") ?? slug(title))
            message.title = title
            message.detail = args.string("detail")
            message.url = args.string("url")
            message.source = "agent"
            message.state = try args.bool("failed") == true ? .failure : .success
            store.apply(message)
            return try shown(message.id, in: store)
        },

        AgentCommand(
            name: "sessions list",
            summary: "Claude Code sessions in the notch (working, waiting or idle) and the permission questions waiting for the person. Only the person answers those, in the notch.",
            example: "notch sessions list --json",
            readOnly: true
        ) { _ in
            let store = try AgentApp.hub()
            let sessions: [JSONObject] = store.agents.map { session in
                var item: JSONObject = ["id": session.id, "agent": session.agent, "project": session.project,
                                        "state": session.state.rawValue, "since": JSON.date(session.since)]
                if let detail = session.detail { item["detail"] = detail }
                return item
            }
            let waiting: [JSONObject] = store.permissions.map {
                ["session": $0.sessionId, "project": $0.project, "tool": $0.tool, "summary": $0.summary,
                 "asked": JSON.date($0.receivedAt)]
            }
            return ["sessions": sessions, "permissions": waiting]
        },

        AgentCommand(
            name: "panel open",
            summary: "Open the notch for a few seconds on every display it's on (Show Notch in the menu).",
            example: "notch panel open"
        ) { _ in
            guard let notch = AgentApp.notch else { throw unavailableInTest }
            notch.show()
            return ["open": true]
        },

        AgentCommand(
            name: "panel close",
            summary: "Close the notch if it's open (Hide Notch in the menu).",
            example: "notch panel close"
        ) { _ in
            guard let notch = AgentApp.notch else { throw unavailableInTest }
            let wasOpen = notch.isExpanded
            if wasOpen { notch.toggle() }
            return ["open": false, "changed": wasOpen]
        },

        AgentCommand(
            name: "settings show",
            summary: "DynamicNotch's settings, as Settings shows them.",
            example: "notch settings show --json",
            readOnly: true
        ) { _ in settings() },

        AgentCommand(
            name: "settings set",
            summary: "Change settings, as Settings does (synced to other Macs when sync is on). Give only the ones to change.",
            params: [
                .init(name: "animation", help: "how the notch opens: grow or fade"),
                .init(name: "displays", help: "where the notch shows: built-in or all"),
                .init(name: "appearance", help: "DynamicNotch's windows: system, light or dark"),
                .init(name: "ask-before-quitting", kind: .boolean, help: "ask before quitting: true or false"),
                .init(name: "show-in-dock", kind: .boolean, help: "a Dock icon: true or false"),
                .init(name: "show-in-menu-bar", kind: .boolean, help: "a menu bar icon: true or false"),
                .init(name: "fold-into-toolhud", kind: .boolean, help: "put the menu in ToolHUD's while ToolHUD runs: true or false"),
            ],
            example: "notch settings set --animation fade --displays all"
        ) { args in try setSettings(args) },

        AgentCommand(
            name: "settings open",
            summary: "Open the Settings window, on the General or Notch pane.",
            params: [.init(name: "pane", positional: true, help: "general or notch (default: the last one shown)")],
            example: "notch settings open notch"
        ) { args in
            let pane = args.string("pane")?.lowercased()
            if let pane, !["general", "notch"].contains(pane) {
                throw AgentError.usage("the pane is general or notch, not \"\(pane)\"")
            }
            if AgentSocket.isTestRun { throw unavailableInTest }
            SettingsWindow.shared.show()
            if let pane, let tabs = NSApp.windows.lazy.compactMap({ $0.contentViewController as? SettingsTabs }).first,
               let index = tabs.tabViewItems.firstIndex(where: { $0.label.lowercased() == pane }) {
                tabs.selectedTabViewItemIndex = index
            }
            return ["opened": pane ?? "settings"]
        },
    ]

    private static let unavailableInTest = AgentError.unavailable("this test copy has no notch or windows on screen; run it against the installed app")

    // MARK: Results

    @MainActor private static func status() throws -> JSONObject {
        let store = try AgentApp.hub()
        let shownActivities = store.visibleActivities
        var result: JSONObject = [
            "version": AppInfo.version,
            "testCopy": AgentSocket.isTestRun,
            "notchOpen": AgentApp.notch?.isExpanded ?? false,
            "displays": AgentApp.notch == nil ? 0 : NotchScreens.targetScreens(Preferences.shared.notchDisplays).count,
            "activities": ["running": shownActivities.filter { $0.state == .running }.count,
                           "finished": shownActivities.filter { $0.state != .running }.count,
                           "waitingToShow": store.activities.count - shownActivities.count],
            "sessions": ["working": store.agents.filter { $0.state == .working }.count,
                         "waiting": store.agents.filter { $0.state == .waiting }.count,
                         "idle": store.agents.filter { $0.state == .idle }.count],
            "permissionsWaiting": store.permissions.count,
            "needsAttention": store.needsAttention,
        ]
        if let track = AgentApp.media?.track {
            result["music"] = ["player": track.player.displayName, "title": track.title, "artist": track.artist,
                               "album": track.album, "playing": track.isPlaying]
        } else {
            result["music"] = NSNull()
        }
        if let volume = AgentApp.volume {
            result["volume"] = ["percent": Int((volume.volume * 100).rounded()), "muted": volume.muted,
                                "device": volume.deviceName, "adjustable": volume.adjustable]
        } else {
            result["volume"] = NSNull()
        }
        return result
    }

    @MainActor private static func activityJSON(_ activity: Activity) -> JSONObject {
        var item: JSONObject = ["id": activity.id, "title": activity.title, "state": activity.state.rawValue,
                                "shown": activity.visible, "startedAt": JSON.date(activity.startedAt)]
        if let progress = activity.progress { item["progress"] = (progress * 1000).rounded() / 1000 }
        if let detail = activity.detail { item["detail"] = detail }
        if let source = activity.source { item["source"] = source }
        if let url = activity.url { item["url"] = url }
        if let symbol = activity.symbol { item["symbol"] = symbol }
        if let finished = activity.finishedAt { item["finishedAt"] = JSON.date(finished) }
        return item
    }

    /// The activity as the notch now has it.
    @MainActor private static func shown(_ id: String, in store: HubStore) throws -> JSONObject {
        guard let activity = store.activities.first(where: { $0.id == id }) else {
            throw AgentError.invalid("DynamicNotch didn't keep \"\(id)\"")
        }
        return activityJSON(activity)
    }

    @MainActor private static func settings() -> JSONObject {
        let prefs = Preferences.shared
        return [
            "animation": prefs.openAnimation.rawValue,
            "displays": prefs.notchDisplays == .all ? "all" : "built-in",
            "appearance": AppAppearance.current.rawValue,
            "askBeforeQuitting": prefs.confirmQuit,
            "showInDock": AppPresence.showInDock,
            "showInMenuBar": AppPresence.showInMenuBar,
            "foldIntoToolHUD": MenuHub.shared.foldIntoToolHUD,
            "syncEnabled": SettingsSync.shared.isEnabled,
            "updates": UpdatePolicy.current.rawValue,
            "updateCheck": UpdateInterval.current.phrase,
            "openAtLogin": LaunchAtLogin.shared.isEnabled,
        ]
    }

    @MainActor private static func setSettings(_ args: Args) throws -> JSONObject {
        // Everything is checked before anything changes.
        let animation = try args.string("animation").map { raw -> NotchAnimation in
            guard let value = NotchAnimation(rawValue: raw.lowercased()) else {
                throw AgentError.usage("--animation must be grow or fade, not \"\(raw)\"")
            }
            return value
        }
        let displays = try args.string("displays").map { raw -> NotchDisplays in
            switch raw.lowercased() {
            case "built-in", "builtin", "built_in": return .builtIn
            case "all", "every": return .all
            default: throw AgentError.usage("--displays must be built-in or all, not \"\(raw)\"")
            }
        }
        let appearance = try args.string("appearance").map { raw -> AppAppearance in
            guard let value = AppAppearance(rawValue: raw.lowercased()) else {
                throw AgentError.usage("--appearance must be system, light or dark, not \"\(raw)\"")
            }
            return value
        }
        let confirmQuit = try args.bool("ask-before-quitting")
        let dock = try args.bool("show-in-dock")
        let menuBar = try args.bool("show-in-menu-bar")
        let fold = try args.bool("fold-into-toolhud")
        guard animation != nil || displays != nil || appearance != nil || confirmQuit != nil || dock != nil
                || menuBar != nil || fold != nil else {
            throw AgentError.usage("nothing to change. Example: notch settings set --animation fade")
        }

        let before = settings()
        let prefs = Preferences.shared
        if let animation { prefs.openAnimation = animation }
        if let displays { prefs.notchDisplays = displays }
        if let confirmQuit { prefs.confirmQuit = confirmQuit }
        if let appearance, appearance != AppAppearance.current {
            // As the Appearance picker in Settings › General does.
            AppAppearance.store.set(appearance.rawValue, forKey: AppAppearance.key)
            SettingsSync.shared.localDidChange()
        }
        if let dock { PresenceSettings.shared.showInDock = dock }
        if let menuBar { PresenceSettings.shared.showInMenuBar = menuBar }
        if let fold { MenuHub.shared.foldIntoToolHUD = fold }
        var after = settings()
        after["changed"] = before.keys.filter { "\(before[$0]!)" != "\(after[$0]!)" }.sorted()
        return after
    }

    // MARK: Values

    /// "Deploy to staging" → "deploy-to-staging", the id `notch start` gives the same title.
    private static func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII { out.unicodeScalars.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? title : String(trimmed.prefix(64))
    }

    /// "40%", "40" or "0.4" → 0.4.
    private static func progress(_ raw: String?) throws -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var percent = false
        if text.hasSuffix("%") { text.removeLast(); percent = true }
        guard let value = Double(text), value >= 0, value.isFinite else {
            throw AgentError.usage("--progress must be like 40%, 40 or 0.4, not \"\(raw!)\"")
        }
        let fraction = (percent || value > 1) ? value / 100 : value
        guard fraction <= 1 else { throw AgentError.usage("--progress can't be over 100%") }
        return fraction
    }
}
