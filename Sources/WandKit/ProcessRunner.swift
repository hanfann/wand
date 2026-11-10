import Foundation
import Darwin

/// Control-plane subprocesses are bounded independently of simulator/UI work.
/// Drain output while waiting so a full pipe cannot deadlock the child. Keep a
/// bounded tail for diagnostics; never retry an ambiguously completed operation.
public enum ProcessRunner {
    public struct Result {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
    }

    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 30, outputLimit: Int = 8 * 1024 * 1024) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run(); try? pipe.fileHandleForWriting.close() }
        catch { return Result(status: -1, output: error.localizedDescription, timedOut: false) }

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var terminationDeadline: TimeInterval?
        var killDeadline: TimeInterval?
        var drainDeadline: TimeInterval?
        var timedOut = false
        var tail = OutputTail(limit: outputLimit)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            // An exited child can leave descendants holding/writing its pipe.
            // Bound that final drain too; do not keep the caller alive forever.
            if !process.isRunning && drainDeadline == nil { drainDeadline = now + 0.1 }
            if let limit = drainDeadline, now >= limit { break }
            if process.isRunning && now >= deadline && !timedOut {
                timedOut = true
                process.terminate()
                terminationDeadline = now + 0.5
            }
            if process.isRunning, let limit = terminationDeadline, now >= limit {
                kill(process.processIdentifier, SIGKILL)
                terminationDeadline = nil
                killDeadline = now + 0.5
            }
            // A child stuck in the kernel must not hold its caller forever.
            if let limit = killDeadline, now >= limit { break }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                buffer.withUnsafeBytes { bytes in
                    tail.append(UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
                }
            } else if !process.isRunning { break }
            else if count < 0 && errno == EINTR { continue }
            else if count == 0 { usleep(10_000) }
            else {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&pollDescriptor, 1, 10)
            }
        }
        // Foundation reaps a killed child asynchronously; never wait without a bound.
        var output = String(decoding: tail.data, as: UTF8.self)
        if tail.truncated { output = "[output truncated to last \(tail.limit) bytes]\n" + output }
        if timedOut {
            output += "\nsubprocess timed out after \(timeout)s; operation may have applied. Inspect state before retrying"
        }
        return Result(status: timedOut ? 124 : process.terminationStatus, output: output, timedOut: timedOut)
    }
}
