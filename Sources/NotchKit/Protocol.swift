import Foundation

/// Where the app and CLI meet. Override with NOTCH_SOCKET for testing.
public enum NotchPaths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DynamicNotch", isDirectory: true)
    }

    public static var socketPath: String {
        ProcessInfo.processInfo.environment["NOTCH_SOCKET"]
            ?? supportDir.appendingPathComponent("hub.sock").path
    }
}

// MARK: - Activities (generic "live activities" pushed from scripts)

public enum ActivityState: String, Codable {
    case running, success, failure
}

public struct ActivityMessage: Codable {
    public var id: String
    public var title: String?
    public var detail: String?
    /// 0...1. nil leaves the current value; a negative value clears it (indeterminate).
    public var progress: Double?
    public var state: ActivityState?
    /// Free-form origin label: "shell", "run", "ci", "script"...
    public var source: String?
    /// Opened when the row is clicked.
    public var url: String?
    /// SF Symbol name for the row icon.
    public var symbol: String?
    /// Only surface the activity once it has been running this many seconds.
    public var showAfter: Double?
    /// Process that owns the activity; it's removed automatically if the process dies.
    public var pid: Int32?
    public var startedAt: Date?
    /// For a finishing message: drop it silently if the activity was never shown.
    public var hideIfUnseen: Bool?

    public init(id: String) { self.id = id }
}

// MARK: - Coding agents (Claude Code sessions)

public enum AgentState: String, Codable {
    case idle, working, waiting, ended
}

public struct AgentMessage: Codable {
    public var sessionId: String
    public var agent: String
    public var cwd: String?
    public var state: AgentState
    public var detail: String?
    public var pid: Int32?

    public init(sessionId: String, agent: String = "Claude Code", cwd: String?, state: AgentState, detail: String? = nil, pid: Int32? = nil) {
        self.sessionId = sessionId
        self.agent = agent
        self.cwd = cwd
        self.state = state
        self.detail = detail
        self.pid = pid
    }
}

/// A blocking question: the connection stays open until the user answers in the notch.
public struct PermissionMessage: Codable {
    public var sessionId: String
    public var agent: String
    public var cwd: String?
    public var tool: String
    public var summary: String
    public var pid: Int32?

    public init(sessionId: String, agent: String = "Claude Code", cwd: String?, tool: String, summary: String, pid: Int32?) {
        self.sessionId = sessionId
        self.agent = agent
        self.cwd = cwd
        self.tool = tool
        self.summary = summary
        self.pid = pid
    }
}

public enum PermissionDecision: String, Codable {
    case allow, deny
    /// Hand the question back to the agent's own prompt.
    case terminal
}

// MARK: - Envelope

public struct HubRequest: Codable {
    public enum Kind: String, Codable {
        case ping, activity, remove, clear, list, agent, permission
    }

    public var kind: Kind
    public var activity: ActivityMessage?
    public var agent: AgentMessage?
    public var permission: PermissionMessage?
    /// For `remove`.
    public var id: String?

    public init(kind: Kind, activity: ActivityMessage? = nil, agent: AgentMessage? = nil, permission: PermissionMessage? = nil, id: String? = nil) {
        self.kind = kind
        self.activity = activity
        self.agent = agent
        self.permission = permission
        self.id = id
    }
}

public struct HubResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var decision: PermissionDecision?
    public var lines: [String]?

    public init(ok: Bool = true, error: String? = nil, decision: PermissionDecision? = nil, lines: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.decision = decision
        self.lines = lines
    }
}

public enum NotchCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
