import Darwin
import Foundation
import NotchKit

let usage = """
notch — push live activities to DynamicNotch

Activities
  notch start <title> [--id ID] [--detail TEXT] [--progress 40%|0.4] [--url URL] [--symbol SF] [--show-after SEC]
  notch update <id> [--title T] [--detail TEXT] [--progress P]
  notch done [<title>] [--id ID] [--detail TEXT] [--fail]
  notch remove <id>
  notch clear                      Remove finished activities
  notch list                       Show what the hub knows about

Wrappers
  notch run [--title T] -- <command...>   Run a command; progress (%, [3/10], ffmpeg time=) is picked up from its output
  notch ci [<pr>] [--repo OWNER/NAME] [--interval SEC]   Watch a PR's checks (needs the GitHub CLI, gh)

Integrations
  notch shell-init zsh             Print zsh hooks: eval "$(notch shell-init zsh)" in ~/.zshrc
  notch setup claude [--print|--remove]   Add (or remove) Claude Code hooks in ~/.claude/settings.json
  notch claude-hook                Entry point Claude Code hooks call (reads hook JSON on stdin)

Ids default to a slug of the title, so `notch start "Deploy"` pairs with `notch done "Deploy"`.
"""

// MARK: - Argument parsing

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    /// Everything after a bare `--`.
    var rest: [String] = []

    init(_ argv: [String], flags known: Set<String> = []) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                rest = Array(argv[(i + 1)...])
                break
            }
            if a.hasPrefix("--"), a.count > 2 {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if known.contains(name) {
                    flags.insert(name)
                } else if i + 1 < argv.count {
                    options[name] = argv[i + 1]
                    i += 1
                } else {
                    fail("--\(name) needs a value")
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    var text: String { (positional + rest).joined(separator: " ") }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
    exit(2)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
}

func slug(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    for ch in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(ch), ch.isASCII { out.unicodeScalars.append(ch) }
        else if !out.hasSuffix("-") { out.append("-") }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? s : String(trimmed.prefix(64))
}

/// "40%", "40", "0.4" → 0.4
func parseProgress(_ s: String?) -> Double? {
    guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    var percent = false
    if s.hasSuffix("%") { s.removeLast(); percent = true }
    guard let v = Double(s) else { fail("bad progress value: \(s)") }
    return (percent || v > 1) ? v / 100 : v
}

/// Activity commands never fail a script just because the hub isn't running.
@discardableResult
func post(_ request: HubRequest, quiet: Bool = false) -> HubResponse? {
    do {
        let r = try HubClient.send(request)
        if !r.ok, !quiet { warn(r.error ?? "request failed") }
        return r
    } catch {
        if !quiet { warn("\(error)") }
        return nil
    }
}

// MARK: - Activity commands

func activity(from args: Args, id: String, title: String?) -> ActivityMessage {
    var m = ActivityMessage(id: id)
    m.title = title
    m.detail = args.options["detail"]
    m.progress = parseProgress(args.options["progress"])
    m.url = args.options["url"]
    m.symbol = args.options["symbol"]
    m.source = args.options["source"]
    m.showAfter = args.options["show-after"].flatMap(Double.init)
    m.pid = args.options["pid"].flatMap(Int32.init)
    return m
}

func start(_ args: Args) {
    let title = args.text
    guard !title.isEmpty || args.options["id"] != nil else { fail("usage: notch start <title>") }
    var m = activity(from: args, id: args.options["id"] ?? slug(title), title: title.isEmpty ? nil : title)
    m.state = .running
    m.startedAt = Date()
    if m.source == nil { m.source = "script" }
    post(HubRequest(kind: .activity, activity: m), quiet: args.flags.contains("quiet"))
}

func update(_ args: Args) {
    guard let id = args.options["id"] ?? args.positional.first else { fail("usage: notch update <id> [--progress P] [--detail TEXT]") }
    let m = activity(from: args, id: id, title: args.options["title"])
    post(HubRequest(kind: .activity, activity: m), quiet: args.flags.contains("quiet"))
}

func done(_ args: Args, failed: Bool) {
    let title = args.text
    guard let id = args.options["id"] ?? (title.isEmpty ? nil : slug(title)) else { fail("usage: notch done <title|--id ID>") }
    var m = activity(from: args, id: id, title: title.isEmpty ? nil : title)
    m.state = failed || args.flags.contains("fail") ? .failure : .success
    m.hideIfUnseen = args.flags.contains("hide-if-unseen")
    post(HubRequest(kind: .activity, activity: m), quiet: args.flags.contains("quiet"))
}

// MARK: - Dispatch

signal(SIGPIPE, SIG_IGN)
let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
let tail = Array(argv.dropFirst())
let commonFlags: Set<String> = ["quiet", "fail", "hide-if-unseen", "print", "remove"]

switch command {
case "start":
    start(Args(tail, flags: commonFlags))
case "update", "progress":
    update(Args(tail, flags: commonFlags))
case "done", "finish", "succeed":
    done(Args(tail, flags: commonFlags), failed: false)
case "fail":
    done(Args(tail, flags: commonFlags), failed: true)
case "remove", "dismiss":
    guard let id = tail.first else { fail("usage: notch remove <id>") }
    post(HubRequest(kind: .remove, id: id))
case "clear":
    post(HubRequest(kind: .clear))
case "list", "ls", "status":
    guard let r = post(HubRequest(kind: .list)) else { exit(1) }
    let lines = r.lines ?? []
    print(lines.isEmpty ? "DynamicNotch is running; nothing to show." : lines.joined(separator: "\n"))
case "ping":
    exit(post(HubRequest(kind: .ping)) == nil ? 1 : 0)
case "run":
    runCommand(Args(tail, flags: commonFlags))
case "ci":
    watchCI(Args(tail, flags: commonFlags))
case "shell-init":
    print(zshInit)
case "claude-hook":
    claudeHook()
case "setup":
    let a = Args(tail, flags: commonFlags)
    guard a.positional.first == "claude" else { fail("usage: notch setup claude [--print|--remove]") }
    setupClaude(printOnly: a.flags.contains("print"), remove: a.flags.contains("remove"))
case "help", "-h", "--help":
    print(usage)
default:
    fail("unknown command '\(command)'. Try `notch help`.")
}
