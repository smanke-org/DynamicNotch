import AppKit
import Foundation

/// Music and Spotify both broadcast track changes as distributed notifications,
/// which need no permission. Controls and artwork go through AppleScript,
/// which triggers a one-time Automation prompt per player.
///
/// (The private MediaRemote "now playing" API is locked to Apple-entitled
/// processes since macOS 15.4, so browsers etc. aren't covered.)
final class NowPlaying: ObservableObject {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var notification: String {
            switch self {
            case .music: return "com.apple.Music.playerInfo"
            case .spotify: return "com.spotify.client.PlaybackStateChanged"
            }
        }

        var displayName: String { self == .music ? "Music" : "Spotify" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    struct Track: Equatable {
        var player: Player
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var key: String { "\(player.rawValue)|\(title)|\(artist)|\(album)" }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?

    private var artworkKey: String?
    private var observers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "dynamicnotch.osascript")

    init() {
        for player in Player.allCases {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(player.notification), object: nil, queue: .main
            ) { [weak self] note in self?.received(note.userInfo ?? [:], from: player) })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier, id == self?.track?.player.rawValue { self?.track = nil }
        })
        for player in Player.allCases where player.isRunning { poll(player) }
    }

    // MARK: Controls

    func playPause() { send("playpause"); track?.isPlaying.toggle() }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func openPlayer() {
        guard let player = track?.player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        guard let player = track?.player, player.isRunning else { return }
        runScript("tell application id \"\(player.rawValue)\" to \(command)") { _ in }
    }

    // MARK: State

    private func received(_ info: [AnyHashable: Any], from player: Player) {
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            if track?.player == player { track = nil }
            return
        }
        let playing = state == "Playing"
        // Don't let a paused player steal the slot from one that's playing.
        if let current = track, current.player != player, current.isPlaying, !playing { return }
        update(Track(player: player,
                     title: info["Name"] as? String ?? "Unknown",
                     artist: info["Artist"] as? String ?? "",
                     album: info["Album"] as? String ?? "",
                     isPlaying: playing))
    }

    private func poll(_ player: Player) {
        let script = """
        tell application id "\(player.rawValue)"
            if player state is stopped then return ""
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)
        end tell
        """
        runScript(script) { [weak self] out in
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 4, let self else { return }
            let playing = parts[0].lowercased() == "playing"
            if let current = self.track, current.isPlaying, !playing { return }
            self.update(Track(player: player, title: parts[1], artist: parts[2], album: parts[3], isPlaying: playing))
        }
    }

    private func update(_ new: Track) {
        if track != new { track = new }
        guard artworkKey != new.key else { return }
        artworkKey = new.key
        artwork = nil
        loadArtwork(for: new)
    }

    private func loadArtwork(for t: Track) {
        let key = t.key
        switch t.player {
        case .spotify:
            runScript("tell application id \"\(t.player.rawValue)\" to return artwork url of current track") { [weak self] out in
                guard let url = URL(string: out.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async { if self?.artworkKey == key { self?.artwork = image } }
                }.resume()
            }
        case .music:
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dynamicnotch-artwork").path
            let script = """
            tell application id "\(t.player.rawValue)"
                try
                    set d to raw data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
            set f to open for access (POSIX file "\(path)") with write permission
            set eof f to 0
            write d to f
            close access f
            return "ok"
            """
            runScript(script) { [weak self] out in
                guard out.hasPrefix("ok"), let image = NSImage(contentsOfFile: path) else { return }
                if self?.artworkKey == key { self?.artwork = image }
            }
        }
    }

    /// Runs AppleScript via osascript off the main thread; completion gets stdout on main.
    private func runScript(_ source: String, completion: @escaping (String) -> Void) {
        scriptQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            DispatchQueue.main.async { completion(text) }
        }
    }
}
