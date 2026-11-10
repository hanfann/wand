import Foundation
import Darwin

/// A serial, persistent NDJSON worker. A failed exchange is never replayed.
/// Private APIs stay in the child; killing one cannot wedge the caller's queue.
public final class WorkerProcess {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: LineReader?
    public var pid: Int32? { process?.processIdentifier }

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }

    public func request(_ message: [String: Any], timeout: TimeInterval,
                        cancelled: (() -> Bool)? = nil) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if process == nil {
            let child = Process(), incoming = Pipe(), outgoing = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            child.environment = environment ?? ProcessInfo.processInfo.environment
            child.standardInput = incoming; child.standardOutput = outgoing
            child.standardError = FileHandle.nullDevice
            try child.run()
            try? incoming.fileHandleForReading.close()
            try? outgoing.fileHandleForWriting.close()
            process = child; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
            reader = LineReader(fd: outgoing.fileHandleForReading.fileDescriptor)
            let fd = incoming.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            guard data.count <= 8 * 1024 * 1024 else { throw failure("worker request too large") }
            let fd = input!.fileDescriptor
            var earlyReply: String?
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard ProcessInfo.processInfo.systemUptime < deadline, cancelled?() != true else {
                        throw failure("worker deadline or cancellation; operation may have applied")
                    }
                    let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    guard n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                        throw failure("worker disconnected; operation may have applied")
                    }
                    // Drain a streaming reply under backpressure: both pipes may be full.
                    if earlyReply == nil {
                        earlyReply = reader?.next(timeout: min(0.005, max(0, deadline - ProcessInfo.processInfo.systemUptime)), cancelled: cancelled)
                    }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                }
            }
            guard let line = earlyReply ?? reader?.next(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), cancelled: cancelled),
                  let data = line.data(using: .utf8),
                  let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw failure("worker timed out, disconnected or was cancelled; operation may have applied; inspect before retrying")
            }
            return reply
        } catch { stop(); throw error }
    }

    public func stop() {
        // Never wait indefinitely for a child trapped in an Apple API/kernel call.
        // Foundation owns reaping; the child also watches parent death.
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; reader = nil; process = nil
    }
    deinit { stop() }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "wand.worker", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
