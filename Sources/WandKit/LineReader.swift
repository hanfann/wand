import Foundation
import Darwin

/// Buffered NDJSON framing. Retains surplus lines for persistent MCP streams;
/// rejects partial EOF/oversized frames instead of executing truncated input.
public final class LineReader {
    private var pending = Data()
    private var offset = 0
    private let fd: Int32
    private let maxBytes: Int

    public init(fd: Int32, maxBytes: Int = 8 * 1024 * 1024) {
        self.fd = fd
        self.maxBytes = maxBytes
    }

    /// A total monotonic deadline, including trickle traffic. nil permits idle
    /// MCP stdin; socket requests/replies always supply a finite deadline.
    public func next(timeout: TimeInterval? = nil, cancelled: (() -> Bool)? = nil) -> String? {
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var scanned = offset
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if cancelled?() == true { return nil }
            // Search contiguous bytes directly. Generic Data collection traversal
            // spends time on per-byte indexing for large AX/JSON replies.
            let newline: Int? = pending.withUnsafeBytes { bytes in
                guard scanned < bytes.count, let base = bytes.baseAddress,
                      let found = memchr(base.advanced(by: scanned), 10, bytes.count - scanned) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
            if let newline {
                guard newline - offset <= maxBytes else { return nil }
                let line = String(data: pending[offset..<newline], encoding: .utf8)
                offset = newline + 1
                if offset == pending.count { pending.removeAll(keepingCapacity: true); offset = 0 }
                return line
            }
            guard pending.count - offset <= maxBytes else { return nil }
            if offset > 0 { pending = Data(pending[offset...]); offset = 0 }
            scanned = pending.count
            if deadline != nil || cancelled != nil {
                let remaining = (deadline ?? .infinity) - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, cancelled == nil ? Double(Int32.max) : 50)))
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 && cancelled != nil { continue }
                guard ready > 0 else { return nil }
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: chunk.prefix(count))
        }
    }
}
