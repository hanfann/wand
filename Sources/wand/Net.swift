import Foundation
import Darwin
import WandKit

// Minimal newline-delimited JSON-over-AF_UNIX transport. Local only: no TCP, no
// network exposure. Socket directory is 0700 and the socket file is 0600.
enum Net {
    static func socketDir() -> String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.wand"
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    // Per-UDID socket so multiple simulators can each have a warm daemon.
    static func socketPath(_ udid: String) -> String { "\(socketDir())/daemon-\(udid).sock" }

    private static func makeAddr(_ path: String) -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = 104  // sockaddr_un.sun_path size on Darwin
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() where i < cap - 1 { dst[i] = CChar(bitPattern: b) }
                dst[min(bytes.count, cap - 1)] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return (addr, len)
    }

    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // --- Server ---

    static func listen(_ path: String) -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configure(fd)
        var (addr, len) = makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { close(fd); return -1 }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); return -1 }
        return fd
    }

    // --- Client ---

    static func connect(_ path: String, timeout: TimeInterval = 1) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configure(fd)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var (addr, len) = makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { close(fd); return -1 }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&descriptor, 1, Int32(max(0, timeout) * 1000)) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                close(fd); return -1
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    // One request/reply per socket. Persistent streams own their LineReader.
    static func readLine(_ fd: Int32, timeout: TimeInterval = 300, cancelled: (() -> Bool)? = nil) -> String? {
        LineReader(fd: fd).next(timeout: timeout, cancelled: cancelled)
    }

    @discardableResult
    static func writeLine(_ fd: Int32, _ s: String, timeout: TimeInterval = 10,
                          cancelled: (() -> Bool)? = nil) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(s.utf8); data.append(10)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard cancelled?() != true, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 10)
            }
            return true
        }
    }
}
