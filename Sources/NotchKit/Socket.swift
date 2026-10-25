import Darwin
import Foundation

public enum HubClientError: Error, CustomStringConvertible {
    case notRunning
    case io(String)

    public var description: String {
        switch self {
        case .notRunning: return "DynamicNotch isn't running (no socket at \(NotchPaths.socketPath))"
        case .io(let s): return s
        }
    }
}

/// Builds a sockaddr_un for `path`, or nil if the path is too long.
public func makeUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// Reads from `fd` until a newline or EOF. Returns nil on error/timeout with nothing read.
public func readLine(fd: Int32, limit: Int = 4 << 20) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count < limit {
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 {
            data.append(buf, count: n)
            if buf[0..<n].contains(0x0A) { break }
        } else if n == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            return data.isEmpty ? nil : data
        }
    }
    if let nl = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: nl) }
    return data
}

public func writeAll(fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = send(fd, p, left, 0)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            left -= n
            p += n
        }
        return true
    }
}

public enum HubClient {
    /// Sends one request and waits up to `timeout` seconds for the reply.
    public static func send(_ request: HubRequest, timeout: TimeInterval = 3) throws -> HubResponse {
        guard var addr = makeUnixAddress(NotchPaths.socketPath) else { throw HubClientError.io("socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HubClientError.io("socket() failed") }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw HubClientError.notRunning }

        var payload = try NotchCoding.encoder().encode(request)
        payload.append(0x0A)
        guard writeAll(fd: fd, payload) else { throw HubClientError.io("write failed") }
        // Deliberately no shutdown(SHUT_WR): the hub treats EOF as "the asker went away".

        guard let line = readLine(fd: fd), !line.isEmpty else { throw HubClientError.io("no reply (timed out)") }
        return try NotchCoding.decoder().decode(HubResponse.self, from: line)
    }
}
