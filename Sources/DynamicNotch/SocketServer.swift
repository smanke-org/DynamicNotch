import Darwin
import Foundation
import NotchKit

/// One client connection. Most requests are answered immediately; permission
/// requests keep the connection open until the user decides in the notch.
final class HubConnection {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var hangupSource: DispatchSourceRead?

    /// Called on the main queue if the client disconnects before we reply.
    var onHangup: (() -> Void)?

    init(fd: Int32) { self.fd = fd }

    func reply(_ response: HubResponse) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if var data = try? NotchCoding.encoder().encode(response) {
            data.append(0x0A)
            _ = writeAll(fd: fd, data)
        }
        closeLocked()
    }

    /// Watch for the client going away (e.g. Claude Code killed the hook or the user answered in the terminal).
    func watchForHangup() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            if recv(self.fd, &byte, 1, MSG_PEEK) <= 0 {
                self.lock.lock()
                let wasOpen = !self.closed
                self.closeLocked()
                self.lock.unlock()
                if wasOpen { DispatchQueue.main.async { self.onHangup?() } }
            }
        }
        lock.lock()
        hangupSource = source
        lock.unlock()
        source.resume()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        if let source = hangupSource {
            hangupSource = nil
            let fd = self.fd
            source.setCancelHandler { close(fd) }
            source.cancel()
        } else {
            close(fd)
        }
    }
}

final class SocketServer {
    typealias Handler = (HubRequest, HubConnection) -> Void

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Returns false if another DynamicNotch already owns the socket.
    func start() throws -> Bool {
        if (try? HubClient.send(HubRequest(kind: .ping), timeout: 1)) != nil { return false }

        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        guard var addr = makeUnixAddress(path) else { throw HubClientError.io("socket path too long") }
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw HubClientError.io("socket() failed") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw HubClientError.io("bind failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(listenFD, 64) == 0 else { throw HubClientError.io("listen failed") }
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        return true
    }

    func stop() {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK on Darwin; we want blocking reads with a timeout.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            DispatchQueue.global().async { [handler] in
                let conn = HubConnection(fd: fd)
                guard let line = readLine(fd: fd), !line.isEmpty else {
                    conn.reply(HubResponse(ok: false, error: "empty request"))
                    return
                }
                do {
                    let request = try NotchCoding.decoder().decode(HubRequest.self, from: line)
                    DispatchQueue.main.async { handler(request, conn) }
                } catch {
                    conn.reply(HubResponse(ok: false, error: "bad request: \(error)"))
                }
            }
        }
    }
}
