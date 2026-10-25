import AppKit
import Foundation
import NotchKit

struct Activity: Identifiable, Equatable {
    let id: String
    var title: String
    var detail: String?
    var progress: Double?
    var state: ActivityState
    var source: String?
    var url: String?
    var symbol: String?
    var startedAt: Date
    var finishedAt: Date?
    var showAt: Date
    var visible: Bool
    var pid: Int32?
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var agent: String
    var project: String
    var state: AgentState
    var detail: String?
    var since: Date
    var pid: Int32?
}

struct PendingPermission: Identifiable {
    let id = UUID()
    let sessionId: String
    let agent: String
    let project: String
    let tool: String
    let summary: String
    let receivedAt = Date()
    let connection: HubConnection
}

/// Everything the notch shows, apart from media/volume. Main-thread only.
final class HubStore: ObservableObject {
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var agents: [AgentSession] = []
    @Published private(set) var permissions: [PendingPermission] = []
    /// Bumped when something starts needing you, so the notch can flash its edge orange.
    @Published private(set) var attentionPulse = 0
    /// Bumped when a shown activity fails, so the notch can shake.
    @Published private(set) var failurePulse = 0

    /// Asks the notch to pop open briefly (or until resolved, for permissions).
    var onPeek: ((TimeInterval) -> Void)?

    /// Ids that finished recently, so a late-arriving "start" (shell hooks race) is ignored.
    private var tombstones: [String: Date] = [:]
    private var timer: Timer?

    static let successLinger: TimeInterval = 20
    static let failureLinger: TimeInterval = 120

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    var visibleActivities: [Activity] { activities.filter(\.visible) }
    var runningCount: Int { visibleActivities.filter { $0.state == .running }.count + agents.filter { $0.state == .working }.count }
    var needsAttention: Bool { !permissions.isEmpty || agents.contains { $0.state == .waiting } }

    // MARK: Requests

    func handle(_ request: HubRequest, _ conn: HubConnection) {
        switch request.kind {
        case .ping:
            conn.reply(HubResponse())
        case .activity:
            guard let msg = request.activity else { return conn.reply(HubResponse(ok: false, error: "missing activity")) }
            apply(msg)
            conn.reply(HubResponse())
        case .remove:
            if let id = request.id { remove(id) }
            conn.reply(HubResponse())
        case .clear:
            clearFinished()
            conn.reply(HubResponse())
        case .list:
            conn.reply(HubResponse(lines: listing()))
        case .agent:
            guard let msg = request.agent else { return conn.reply(HubResponse(ok: false, error: "missing agent")) }
            apply(msg)
            conn.reply(HubResponse())
        case .permission:
            guard let msg = request.permission else { return conn.reply(HubResponse(ok: false, error: "missing permission")) }
            ask(msg, conn)
        }
    }

    private func apply(_ msg: ActivityMessage) {
        let now = Date()
        if let i = activities.firstIndex(where: { $0.id == msg.id }) {
            var a = activities[i]
            let wasRunning = a.state == .running
            if let t = msg.title { a.title = t }
            if let d = msg.detail { a.detail = d }
            if let p = msg.progress { a.progress = p < 0 ? nil : min(max(p, 0), 1) }
            if let u = msg.url { a.url = u }
            if let s = msg.symbol { a.symbol = s }
            if let state = msg.state { a.state = state }
            if wasRunning && a.state != .running {
                if msg.hideIfUnseen == true && !a.visible {
                    remove(msg.id)
                    return
                }
                a.finishedAt = now
                if a.state == .success { a.progress = 1 }
                a.visible = true
                activities[i] = a
                if a.state == .failure { failurePulse += 1 }
                onPeek?(3.5)
                return
            }
            if !wasRunning && a.state == .running {
                // Same id started again: treat it as a fresh run.
                a.finishedAt = nil
                a.startedAt = msg.startedAt ?? now
                if msg.progress == nil { a.progress = nil }
            }
            activities[i] = a
            return
        }

        let state = msg.state ?? .running
        // A delayed (shell-style) start that lost the race with its own finish.
        if tombstones[msg.id] != nil && state == .running && msg.showAfter != nil { return }
        if state != .running && msg.hideIfUnseen == true {
            tombstones[msg.id] = now
            return
        }
        let started = msg.startedAt ?? now
        let showAt = started.addingTimeInterval(msg.showAfter ?? 0)
        let visible = showAt <= now
        activities.append(Activity(
            id: msg.id,
            title: msg.title ?? msg.id,
            detail: msg.detail,
            progress: msg.progress.map { $0 < 0 ? nil : min(max($0, 0), 1) } ?? (state == .success ? 1 : nil),
            state: state,
            source: msg.source,
            url: msg.url,
            symbol: msg.symbol,
            startedAt: started,
            finishedAt: state == .running ? nil : now,
            showAt: showAt,
            visible: visible,
            pid: msg.pid
        ))
        if visible {
            if state == .failure { failurePulse += 1 }
            onPeek?(state == .running ? 2.5 : 3.5)
        }
    }

    private func remove(_ id: String) {
        activities.removeAll { $0.id == id }
        tombstones[id] = Date()
    }

    func dismiss(_ activity: Activity) { remove(activity.id) }

    func clearFinished() { activities.removeAll { $0.state != .running } }

    private func apply(_ msg: AgentMessage) {
        if msg.state == .ended {
            agents.removeAll { $0.id == msg.sessionId }
            for p in permissions where p.sessionId == msg.sessionId { resolve(p, .terminal) }
            return
        }
        let project = msg.cwd.map { ($0 as NSString).lastPathComponent } ?? "Session"
        if let i = agents.firstIndex(where: { $0.id == msg.sessionId }) {
            let old = agents[i].state
            agents[i].state = msg.state
            agents[i].project = project
            if let d = msg.detail { agents[i].detail = d }
            if let pid = msg.pid { agents[i].pid = pid }
            if old != msg.state {
                agents[i].since = Date()
                // Surface the moments that matter: needs you, or just finished.
                if msg.state == .waiting { attentionPulse += 1 }
                if msg.state == .waiting || (old == .working && msg.state == .idle) { onPeek?(4) }
            }
        } else {
            agents.append(AgentSession(id: msg.sessionId, agent: msg.agent, project: project, state: msg.state,
                                       detail: msg.detail, since: Date(), pid: msg.pid))
            if msg.state == .waiting { attentionPulse += 1; onPeek?(4) }
        }
    }

    private func ask(_ msg: PermissionMessage, _ conn: HubConnection) {
        let project = msg.cwd.map { ($0 as NSString).lastPathComponent } ?? "Session"
        let pending = PendingPermission(sessionId: msg.sessionId, agent: msg.agent, project: project,
                                        tool: msg.tool, summary: msg.summary, connection: conn)
        permissions.append(pending)
        apply(AgentMessage(sessionId: msg.sessionId, agent: msg.agent, cwd: msg.cwd, state: .waiting,
                           detail: "Wants to use \(msg.tool)", pid: msg.pid))
        conn.onHangup = { [weak self] in self?.permissions.removeAll { $0.id == pending.id } }
        conn.watchForHangup()
        NSSound(named: "Tink")?.play()
        attentionPulse += 1
        onPeek?(8)
    }

    func resolve(_ permission: PendingPermission, _ decision: PermissionDecision) {
        permissions.removeAll { $0.id == permission.id }
        permission.connection.reply(HubResponse(decision: decision))
        if decision != .terminal, let i = agents.firstIndex(where: { $0.id == permission.sessionId }) {
            agents[i].state = .working
            agents[i].detail = decision == .allow ? "Allowed \(permission.tool)" : "Denied \(permission.tool)"
            agents[i].since = Date()
        }
    }

    // MARK: Housekeeping

    private func tick() {
        let now = Date()
        var changed = activities
        for i in changed.indices where !changed[i].visible && changed[i].showAt <= now {
            changed[i].visible = true
        }
        changed.removeAll { a in
            guard let done = a.finishedAt else { return false }
            return now.timeIntervalSince(done) > (a.state == .failure ? Self.failureLinger : Self.successLinger)
        }
        // Drop running items whose owning process is gone (closed terminal, killed script).
        changed.removeAll { a in a.state == .running && a.pid.map { !Self.isAlive($0) } == true }
        if changed != activities { activities = changed }

        let liveAgents = agents.filter { $0.pid.map(Self.isAlive) ?? true }
        if liveAgents != agents { agents = liveAgents }

        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < 120 }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func listing() -> [String] {
        var lines: [String] = []
        for p in permissions { lines.append("? \(p.project): \(p.tool) — \(p.summary)") }
        for a in agents { lines.append("@ \(a.project) [\(a.state.rawValue)] \(a.detail ?? "")") }
        for a in activities {
            let pct = a.progress.map { " \(Int($0 * 100))%" } ?? ""
            lines.append("\(a.visible ? "•" : "·") \(a.id) [\(a.state.rawValue)\(pct)] \(a.title)\(a.detail.map { " — \($0)" } ?? "")")
        }
        return lines
    }
}
