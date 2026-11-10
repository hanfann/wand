import Foundation
import Darwin

public enum WorkerLifetime {
    /// A worker stalled in a private API still exits if its owning daemon dies.
    /// Keep the returned source alive for the worker's entire lifetime.
    public static func monitorParent() -> DispatchSourceTimer {
        let parent = getppid()
        if parent == 1 { _exit(0) }
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler { if getppid() != parent { _exit(0) } }
        monitor.resume()
        return monitor
    }
}
