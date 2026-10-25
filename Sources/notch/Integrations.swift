import Darwin
import Foundation
import NotchKit

// MARK: - zsh

let zshInit = #"""
# DynamicNotch: commands that run longer than $NOTCH_SHOW_AFTER seconds show up in the notch.
# Install: add `eval "$(notch shell-init zsh)"` to ~/.zshrc
zmodload zsh/datetime 2>/dev/null
typeset -g _notch_id=""
: ${NOTCH_SHOW_AFTER:=10}
(( ${+NOTCH_IGNORE} )) || typeset -ga NOTCH_IGNORE=(
  vim nvim vi nano emacs less more man top htop btop ssh mosh tmux screen
  claude watch fzf tail python python3 node irb ipython psql mysql sqlite3 notch
)
_notch_preexec() {
  local cmd=${${(z)1}[1]}
  if (( ${NOTCH_IGNORE[(Ie)$cmd]} )); then _notch_id=""; return; fi
  _notch_id="sh-$$-${EPOCHREALTIME/./}"
  notch start --id "$_notch_id" --source shell --symbol terminal.fill \
    --show-after "$NOTCH_SHOW_AFTER" --pid $$ --detail "${PWD:t}" --quiet -- "$1" &>/dev/null &!
}
_notch_precmd() {
  local code=$?
  [[ -z $_notch_id ]] && return
  local id=$_notch_id; _notch_id=""
  if (( code == 0 )); then
    notch done --id "$id" --hide-if-unseen --quiet &>/dev/null &!
  else
    notch done --id "$id" --fail --detail "exit $code" --hide-if-unseen --quiet &>/dev/null &!
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _notch_preexec
add-zsh-hook precmd _notch_precmd
"""#

// MARK: - GitHub checks

private func gh(_ args: [String]) -> (status: Int32, output: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["gh"] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (127, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func watchCI(_ args: Args) -> Never {
    var scope: [String] = []
    if let repo = args.options["repo"] { scope += ["--repo", repo] }
    let pr = args.positional.first.map { [$0] } ?? []
    let interval = args.options["interval"].flatMap(Double.init) ?? 15

    let view = gh(["pr", "view"] + pr + ["--json", "number,title,url"] + scope)
    if view.status == 127 { fail("needs the GitHub CLI: brew install gh") }
    guard view.status == 0,
          let info = try? JSONSerialization.jsonObject(with: view.output) as? [String: Any],
          let number = info["number"] as? Int else {
        fail("couldn't find that pull request (is `gh auth login` done, and is there a PR for this branch?)")
    }

    let id = "ci-pr-\(number)"
    var m = ActivityMessage(id: id)
    m.title = "CI · #\(number) \((info["title"] as? String ?? "").prefix(40))"
    m.url = info["url"] as? String
    m.symbol = "checkmark.seal"
    m.source = "ci"
    m.state = .running
    m.pid = getpid()
    m.startedAt = Date()
    m.detail = "Waiting for checks…"
    post(HubRequest(kind: .activity, activity: m))

    while true {
        let r = gh(["pr", "checks", "\(number)", "--json", "name,bucket"] + scope)
        let checks = (try? JSONSerialization.jsonObject(with: r.output) as? [[String: Any]]) ?? []
        let counted = checks.filter { ($0["bucket"] as? String) != "skipping" }
        let failing = counted.filter { ["fail", "cancel"].contains($0["bucket"] as? String ?? "") }
        let pending = counted.filter { ($0["bucket"] as? String) == "pending" }

        var u = ActivityMessage(id: id)
        if !counted.isEmpty {
            let finished = counted.count - pending.count
            u.progress = Double(finished) / Double(counted.count)
            var detail = "\(finished)/\(counted.count) checks done"
            if let f = failing.first?["name"] as? String { detail += " · failing: \(f)" }
            u.detail = detail
        }
        if !counted.isEmpty && pending.isEmpty {
            u.state = failing.isEmpty ? .success : .failure
            u.detail = failing.isEmpty ? "All \(counted.count) checks passed" : "\(failing.count) failing: \(failing.compactMap { $0["name"] as? String }.joined(separator: ", "))"
            post(HubRequest(kind: .activity, activity: u))
            print(u.detail ?? "")
            exit(failing.isEmpty ? 0 : 1)
        }
        post(HubRequest(kind: .activity, activity: u), quiet: true)
        Thread.sleep(forTimeInterval: interval)
    }
}

// MARK: - Claude Code

/// Short status line or full description of what a tool call does.
func toolSummary(_ tool: String, _ input: [String: Any], long: Bool) -> String {
    func s(_ k: String) -> String? { input[k] as? String }
    let text: String
    switch tool {
    case "Bash":
        text = s("command") ?? ""
    case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
        let path = s("file_path") ?? s("notebook_path") ?? ""
        text = long ? path : (path as NSString).lastPathComponent
    case "WebFetch":
        text = s("url") ?? ""
    case "WebSearch":
        text = s("query") ?? ""
    case "Grep", "Glob":
        text = s("pattern") ?? ""
    case "Task", "Agent":
        text = s("description") ?? s("prompt") ?? ""
    default:
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }
    if long { return String(text.prefix(600)) }
    let first = text.split(separator: "\n").first.map(String.init) ?? text
    return first.isEmpty ? tool : "\(tool): \(first.prefix(90))"
}

private func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

/// The Claude Code process: our parent, or our grandparent if a shell sits in between.
/// The hub uses it to clear sessions whose terminal was closed without a SessionEnd.
private func claudePID() -> Int32? {
    let parent = getppid()
    guard parent > 1 else { return nil }
    if let (pp, name) = processInfo(parent), ["sh", "bash", "zsh", "dash"].contains(name), pp > 1 { return pp }
    return parent
}

private func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
        FileHandle.standardOutput.write(data)
    }
}

func claudeHook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

    let event = obj["hook_event_name"] as? String ?? ""
    let session = obj["session_id"] as? String ?? "unknown"
    let cwd = obj["cwd"] as? String
    let pid = claudePID()

    func agent(_ state: AgentState, _ detail: String?) {
        let msg = AgentMessage(sessionId: session, cwd: cwd, state: state, detail: detail, pid: pid)
        _ = try? HubClient.send(HubRequest(kind: .agent, agent: msg), timeout: 1)
    }
    func firstLine(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        return s.split(separator: "\n").first.map { String($0.prefix(100)) }
    }

    switch event {
    case "SessionStart":
        agent(.idle, "Session started")
    case "UserPromptSubmit":
        agent(.working, firstLine(obj["prompt"]))
    case "PreToolUse":
        agent(.working, toolSummary(obj["tool_name"] as? String ?? "Tool", obj["tool_input"] as? [String: Any] ?? [:], long: false))
    case "Notification":
        // idle_prompt fires a while after every finished turn; that's not "needs you".
        let type = obj["notification_type"] as? String ?? ""
        if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) {
            agent(.waiting, firstLine(obj["message"]) ?? "Needs your input")
        }
    case "PermissionRequest":
        let tool = obj["tool_name"] as? String ?? "a tool"
        let summary = toolSummary(tool, obj["tool_input"] as? [String: Any] ?? [:], long: true)
        let timeout = ProcessInfo.processInfo.environment["NOTCH_APPROVAL_TIMEOUT"].flatMap(Double.init) ?? 120
        let msg = PermissionMessage(sessionId: session, cwd: cwd, tool: tool, summary: summary, pid: pid)
        // No reply (hub not running, timeout, "answer in terminal") → print nothing, so Claude Code asks as usual.
        guard let r = try? HubClient.send(HubRequest(kind: .permission, permission: msg), timeout: timeout) else { exit(0) }
        switch r.decision {
        case .allow?:
            emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]])
        case .deny?:
            emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                         "decision": ["behavior": "deny", "message": "The user denied this from DynamicNotch."]]])
        default:
            break
        }
    case "Stop":
        agent(.idle, firstLine(obj["last_assistant_message"]).map { "Done · \($0)" } ?? "Done")
    case "StopFailure":
        agent(.idle, "Stopped with an error")
    case "SessionEnd":
        agent(.ended, nil)
    default:
        break
    }
    exit(0)
}

/// The path hooks should call: argv[0] as given (keeping a ~/.local/bin symlink stable), else a PATH lookup.
private func selfPath() -> String {
    let argv0 = CommandLine.arguments[0]
    if argv0.contains("/") { return URL(fileURLWithPath: argv0).standardizedFileURL.path }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/\(argv0)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return argv0
}

private func isOurs(_ group: Any) -> Bool {
    guard let hooks = (group as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
    return hooks.contains { ($0["command"] as? String)?.contains("notch") == true && ($0["command"] as? String)?.contains("claude-hook") == true }
}

func setupClaude(printOnly: Bool, remove: Bool) -> Never {
    let command = "'\(selfPath().replacingOccurrences(of: "'", with: "'\\''"))' claude-hook"
    let approvalTimeout = ProcessInfo.processInfo.environment["NOTCH_APPROVAL_TIMEOUT"].flatMap(Int.init) ?? 120
    let asyncEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"]

    var ours: [String: [String: Any]] = [:]
    for event in asyncEvents {
        ours[event] = ["hooks": [["type": "command", "command": command, "async": true]]]
    }
    // Blocking: Claude Code waits for the answer from the notch.
    ours["PermissionRequest"] = ["hooks": [["type": "command", "command": command, "timeout": approvalTimeout + 15]]]

    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if printOnly {
        let snippet = ["hooks": ours.mapValues { [$0] }]
        print(String(data: try! JSONSerialization.data(withJSONObject: snippet, options: options), encoding: .utf8)!)
        exit(0)
    }

    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: url) {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("\(url.path) isn't valid JSON; not touching it. Use `notch setup claude --print` and merge by hand.")
        }
        settings = parsed
        try? data.write(to: url.appendingPathExtension("dynamicnotch-backup"))
    }

    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in Set(asyncEvents + ["PermissionRequest"]) {
        var groups = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
        if !remove, let group = ours[event] { groups.append(group) }
        hooks[event] = groups.isEmpty ? nil : groups
    }
    settings["hooks"] = hooks.isEmpty ? nil : hooks

    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: options).write(to: url, options: .atomic)
    } catch {
        fail("couldn't write \(url.path): \(error.localizedDescription)")
    }
    if remove {
        print("Removed DynamicNotch hooks from \(url.path).")
    } else {
        print("Added DynamicNotch hooks to \(url.path) (backup: settings.json.dynamicnotch-backup).")
        print("Hooks call: \(command)")
        print("New Claude Code sessions will show up in the notch; permission prompts wait \(approvalTimeout)s for you there.")
    }
    exit(0)
}
