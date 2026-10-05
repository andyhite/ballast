import Darwin
import Dispatch
import Foundation

/// Unix-socket command channel for `ballast send`: one line in, one line
/// (`ok`, `ok: <msg>` or `error: <msg>`) out. Owner-only (0600 in a 0700 directory).
@MainActor
final class CommandSocket {
    static var defaultPath: String { BallastCLI.lockDirectory.appendingPathComponent("cmd.sock").path }

    private let path: String
    private let handler: @MainActor (String) -> String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping @MainActor (String) -> String) {
        self.path = path
        self.handler = handler
    }

    private nonisolated static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    func start() -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        chmod(directory, 0o700)
        // Only the run-lock holder calls this, so a socket left here is stale.
        unlink(path)
        guard var addr = Self.address(path) else {
            Log.wm.error("command socket path too long: \(self.path, privacy: .public)")
            return false
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else {
            Log.wm.error("command socket: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(s, 8) == 0 else {
            Log.wm.error("command socket: \(String(cString: strerror(errno)), privacy: .public)")
            close(s)
            unlink(path)
            return false
        }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptOne() } }
        src.resume()
        source = src
        return true
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        Self.setTimeouts(client, seconds: 1)
        // ponytail: client read on main, bounded by a 1 s timeout; move to a queue if that ever stalls the UI
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 4096, !data.contains(10) {
            let n = read(client, &buffer, min(buffer.count, 4096 - data.count))
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let reply: String
        if let line = data.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false).first,
           let text = String(data: Data(line), encoding: .utf8) {
            reply = handler(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            reply = "error: invalid UTF-8"
        }
        let out = Array((reply + "\n").utf8)
        _ = write(client, out, out.count)
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(path)
    }

    private nonisolated static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    struct SendError: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        init(errno code: Int32) { self.description = String(cString: strerror(code)) }
    }

    /// Client side of `ballast send`: the reply without its newline, or the failure.
    nonisolated static func send(_ line: String, path: String) -> Result<String, SendError> {
        guard var addr = address(path) else { return .failure(SendError("socket path too long")) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return .failure(SendError(errno: errno)) }
        defer { close(s) }
        setTimeouts(s, seconds: 5)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(SendError(errno: errno)) }
        let out = Array((line + "\n").utf8)
        guard write(s, out, out.count) == out.count else { return .failure(SendError(errno: errno)) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) {
            let n = read(s, &buffer, buffer.count)
            if n < 0 { return .failure(SendError(errno: errno)) }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let reply = String(decoding: data.prefix { $0 != 10 }, as: UTF8.self)
        return .success(reply)
    }
}
