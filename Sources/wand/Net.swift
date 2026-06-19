import Foundation
import Darwin

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

    // --- Server ---

    static func listen(_ path: String) -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
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

    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var (addr, len) = makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
    }

    // Read one '\n'-terminated line (without the newline). nil on EOF.
    static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
            if byte == 0x0A { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
    }

    static func writeLine(_ fd: Int32, _ s: String) {
        var data = Data(s.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var p = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n <= 0 { break }
                p = p.advanced(by: n)
                remaining -= n
            }
        }
    }
}
