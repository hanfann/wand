// Compile with ProcessRunner.swift (and OutputTail.swift for the ring-buffer
// candidate). This exercises the real reader/child lifecycle without a simulator.
import Foundation

@main
struct OutputBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let samples = Int(args[3]), samples >= 5 else {
            fatalError("usage: benchmark EMITTER RESULTS_JSON SAMPLES")
        }
        var results: [String: Any] = [:]
        for (name, bytes, limit) in [("small", 4096, 8 * 1024 * 1024),
                                    ("within_limit", 256 * 1024, 8 * 1024 * 1024),
                                    ("overflow", 32 * 1024 * 1024, 8 * 1024 * 1024)] {
            var times: [Double] = []
            for index in 0...samples {
                let start = ProcessInfo.processInfo.systemUptime
                let result = ProcessRunner.run(args[1], [String(bytes)], timeout: 15, outputLimit: limit)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let prefix = bytes > limit ? "[output truncated to last \(limit) bytes]\n" : ""
                guard result.status == 0, !result.timedOut,
                      result.output == prefix + String(repeating: "x", count: min(bytes, limit)) else {
                    fatalError("incorrect or incomplete subprocess output: \(name), status \(result.status)")
                }
                if index > 0 { times.append(milliseconds) }
            }
            let sorted = times.sorted()
            let result: [String: Any] = ["n": samples, "median_ms": sorted[samples / 2],
                "p95_ms": sorted[Int(ceil(Double(samples) * 0.95)) - 1], "max_ms": sorted.last!, "samples_ms": times]
            results[name] = result
            print("\(name): median \(sorted[samples / 2]) ms, p95 \(sorted[Int(ceil(Double(samples) * 0.95)) - 1]) ms")
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[2]))
    }
}
