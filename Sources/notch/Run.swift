import Darwin
import Foundation
import NotchKit

/// Child pid for signal forwarding (C signal handlers can't capture context).
private var childPID: pid_t = 0

/// Picks progress and a status line out of a command's output as it streams by.
final class OutputScanner {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var progress: Double?
    private(set) var lastLine: String?
    private var ffmpegDuration: Double?

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    private static let percent = try! NSRegularExpression(pattern: "(\\d{1,3}(?:\\.\\d+)?)\\s?%")
    private static let fraction = try! NSRegularExpression(pattern: "\\[\\s*(\\d+)\\s*/\\s*(\\d+)\\s*\\]")
    private static let duration = try! NSRegularExpression(pattern: "Duration: (\\d+):(\\d+):(\\d+(?:\\.\\d+)?)")
    private static let ffTime = try! NSRegularExpression(pattern: "time=(\\d+):(\\d+):(\\d+(?:\\.\\d+)?)")

    func feed(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        if buffer.count > 8192 { buffer = String(buffer.suffix(4096)) }

        let clean = Self.replace(Self.ansi, in: buffer, with: "")
        let lines = clean.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last { lastLine = String(last.prefix(120)) }

        let recent = String(clean.suffix(600))
        if let d = Self.lastMatch(Self.duration, in: clean) { ffmpegDuration = Self.seconds(d, in: clean) }
        if let dur = ffmpegDuration, dur > 0, let t = Self.lastMatch(Self.ffTime, in: recent) {
            progress = min(1, Self.seconds(t, in: recent) / dur)
        } else if let m = Self.lastMatch(Self.fraction, in: recent),
                  let a = Double(Self.group(m, 1, in: recent)), let b = Double(Self.group(m, 2, in: recent)), b > 0 {
            progress = min(1, a / b)
        } else if let m = Self.lastMatch(Self.percent, in: recent), let v = Double(Self.group(m, 1, in: recent)), v <= 100 {
            progress = v / 100
        }
    }

    var snapshot: (Double?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (progress, lastLine)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    private static func lastMatch(_ re: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).last
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    private static func seconds(_ m: NSTextCheckingResult, in s: String) -> Double {
        (Double(group(m, 1, in: s)) ?? 0) * 3600 + (Double(group(m, 2, in: s)) ?? 0) * 60 + (Double(group(m, 3, in: s)) ?? 0)
    }
}

func runCommand(_ args: Args) -> Never {
    let command = args.rest.isEmpty ? args.positional : args.rest
    guard !command.isEmpty else { fail("usage: notch run [--title T] -- <command...>") }

    let title = args.options["title"] ?? String(command.joined(separator: " ").prefix(60))
    let id = args.options["id"] ?? "run-\(getpid())"
    let quiet = true

    var startMsg = ActivityMessage(id: id)
    startMsg.title = title
    startMsg.state = .running
    startMsg.source = "run"
    startMsg.symbol = args.options["symbol"] ?? "terminal.fill"
    startMsg.url = args.options["url"]
    startMsg.pid = getpid()
    startMsg.startedAt = Date()
    startMsg.showAfter = args.options["show-after"].flatMap(Double.init)
    post(HubRequest(kind: .activity, activity: startMsg), quiet: quiet)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.standardInput = FileHandle.standardInput
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    // Ctrl-C reaches the child via the terminal's process group; we just need to survive it to report.
    signal(SIGINT) { _ in }
    signal(SIGTERM) { sig in if childPID > 0 { kill(childPID, sig) } }
    signal(SIGHUP) { sig in if childPID > 0 { kill(childPID, sig) } }

    do { try process.run() } catch {
        var m = ActivityMessage(id: id)
        m.state = .failure
        m.detail = "Couldn't start: \(error.localizedDescription)"
        post(HubRequest(kind: .activity, activity: m), quiet: quiet)
        fail("couldn't run \(command[0]): \(error.localizedDescription)")
    }
    childPID = process.processIdentifier

    let scanner = OutputScanner()
    let group = DispatchGroup()
    let sendQueue = DispatchQueue(label: "notch.send")
    var lastSent = Date.distantPast
    let sentLock = NSLock()

    func pump(_ pipe: Pipe, to out: FileHandle) {
        group.enter()
        Thread.detachNewThread {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                out.write(data)
                scanner.feed(data)

                sentLock.lock()
                let due = Date().timeIntervalSince(lastSent) > 0.3
                if due { lastSent = Date() }
                sentLock.unlock()
                if due {
                    let (p, line) = scanner.snapshot
                    var m = ActivityMessage(id: id)
                    m.progress = p
                    m.detail = line
                    sendQueue.async { post(HubRequest(kind: .activity, activity: m), quiet: true) }
                }
            }
            group.leave()
        }
    }
    pump(outPipe, to: .standardOutput)
    pump(errPipe, to: .standardError)

    process.waitUntilExit()
    group.wait()
    sendQueue.sync {}

    let status = process.terminationStatus
    let code = process.terminationReason == .uncaughtSignal ? 128 + status : status
    var end = ActivityMessage(id: id)
    end.state = code == 0 ? .success : .failure
    end.detail = code == 0 ? scanner.snapshot.1 : "exit \(code)\(scanner.snapshot.1.map { " · \($0)" } ?? "")"
    end.hideIfUnseen = startMsg.showAfter != nil ? true : nil
    post(HubRequest(kind: .activity, activity: end), quiet: quiet)
    exit(code)
}
