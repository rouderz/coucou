import Foundation
import Darwin

// MARK: - Transport port (#17)
// How hook relays reach the app: a Unix socket on macOS (and Linux); a named pipe on Windows.
// One message per connection: a line of JSON in, a line of JSON back.

/// One relay waiting for an answer. `reply` sends the line and ends the connection.
protocol HookConnection: AnyObject, Sendable {
    func reply(_ line: String)
}

protocol HookTransport: Sendable {
    /// Starts listening; `onMessage` runs on a background thread for each message.
    func start(onMessage: @escaping @Sendable (_ raw: Data, _ connection: any HookConnection) -> Void)
}

/// Newline-delimited JSON over a Unix domain socket.
final class UnixSocketTransport: HookTransport, @unchecked Sendable {
    let path: String

    init(path: String) { self.path = path }

    func start(onMessage: @escaping @Sendable (Data, any HookConnection) -> Void) {
        let path = self.path
        Thread.detachNewThread {
            try? FileManager.default.removeItem(atPath: path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let cpath = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 10) == 0 else { close(fd); return }

            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                Thread.detachNewThread {
                    let connection = UnixSocketConnection(fd: client)
                    onMessage(connection.readLine(), connection)
                }
            }
        }
    }
}

final class UnixSocketConnection: HookConnection, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Everything up to the first newline.
    func readLine() -> Data {
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
        }
        return raw
    }

    func reply(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        close(fd)
    }

    deinit { if !closed { close(fd) } }
}
