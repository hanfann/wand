import Foundation

/// Per-request measurements. Exclusive times partition nested work; inclusive
/// times are diagnostic and must not be summed across parent/child phases.
public final class PhaseProfile {
    public struct Metric {
        public var calls = 0
        public var inclusiveMs = 0.0
        public var exclusiveMs = 0.0
    }
    private struct Span { let started: Double; var children = 0.0 }
    private let clock: () -> Double
    private let started: Double
    private var stack: [Span] = []
    public private(set) var phases: [String: Metric] = [:]

    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        started = clock()
    }
    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        stack.append(Span(started: clock()))
        defer {
            let span = stack.removeLast()
            let elapsed = max(0, clock() - span.started)
            var metric = phases[name, default: Metric()]
            metric.calls += 1
            metric.inclusiveMs += elapsed * 1000
            metric.exclusiveMs += max(0, elapsed - span.children) * 1000
            phases[name] = metric
            if !stack.isEmpty { stack[stack.count - 1].children += elapsed }
        }
        return try body()
    }
    public var elapsedMs: Double { max(0, clock() - started) * 1000 }
    public var json: [String: Any] {
        ["elapsed_ms": elapsedMs, "phases": phases.mapValues {
            ["calls": $0.calls, "inclusive_ms": $0.inclusiveMs, "exclusive_ms": $0.exclusiveMs] as [String: Any]
        }]
    }
}
