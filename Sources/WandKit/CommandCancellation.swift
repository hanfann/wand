import Foundation

/// Cancellation is advisory once dispatch begins: it never means rollback.
public final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var sent = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var wasDispatched: Bool { lock.lock(); defer { lock.unlock() }; return sent }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    /// Atomic with cancellation, so a cancelled queued request never reaches a socket.
    public func beginDispatch() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        sent = true; return true
    }
}
