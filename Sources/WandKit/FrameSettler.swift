import Foundation

/// Wait for three equal rendered samples after a minimum settling interval.
/// Sampling before the final stability window cannot end the wait, so defer that
/// work while continuing to check cancellation at the normal polling cadence.
public enum FrameSettler {
    public enum Outcome: Equatable { case stable, unavailable, cancelled, deadline }

    public static func run(minimum: Double, maximum: Double, interval: Double = 0.09,
                           now: () -> Double, pause: (Double) -> Void,
                           cancelled: () -> Bool, fingerprint: () -> UInt64) -> Outcome {
        precondition(minimum >= 0 && maximum >= 0 && interval > 0)
        let start = now(), deadline = start + maximum
        let firstSample = start + max(0, minimum - 2 * interval)
        var previous: UInt64 = 0, stableReads = 0
        while now() < deadline {
            if cancelled() { return .cancelled }
            let current = now()
            if current < firstSample {
                pause(max(0, min(interval, firstSample - current, deadline - current)))
                continue
            }
            let signature = fingerprint()
            guard signature != 0 else { return .unavailable }
            stableReads = signature == previous ? stableReads + 1 : 0
            if stableReads >= 2 && now() - start >= minimum { return .stable }
            previous = signature
            pause(max(0, min(interval, deadline - now())))
        }
        return .deadline
    }
}
