// Compile alongside LineReader.swift. Cached local input isolates framing cost
// from process startup, simulator work and producer/network scheduling.
import Foundation
import Darwin

@main
struct FramingBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, let samples = Int(args[2]), samples >= 5 else {
            fatalError("usage: framing-benchmark RESULTS_JSON SAMPLES")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-framing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("input.ndjson").path
        var results: [String: Any] = [:]
        for (name, expected) in [
            ("line_1k", [String(repeating: "x", count: 1024)]),
            ("line_128k", [String(repeating: "x", count: 128 * 1024)]),
            ("line_4m", [String(repeating: "x", count: 4 * 1024 * 1024)]),
            ("coalesced_1000", (0..<1000).map { "\($0):" + String(repeating: "盆栽🌱", count: 8) })
        ] {
            try Data((expected.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { fatalError("could not open fixture") }
            defer { close(fd) }
            var times: [Double] = []
            for sample in 0...samples {
                guard lseek(fd, 0, SEEK_SET) == 0 else { fatalError("could not rewind fixture") }
                let reader = LineReader(fd: fd)
                let start = ProcessInfo.processInfo.systemUptime
                var actual: [String] = []
                while let line = reader.next(timeout: 5) { actual.append(line) }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                guard actual == expected else { fatalError("lost/reordered/changed frame: \(name)") }
                if sample > 0 { times.append(elapsed) }
            }
            let sorted = times.sorted(), p95 = sorted[Int(ceil(Double(samples) * 0.95)) - 1]
            results[name] = ["n": samples, "median_ms": sorted[samples / 2], "p95_ms": p95,
                             "max_ms": sorted.last!, "samples_ms": times]
            print("\(name): median \(sorted[samples / 2]) ms, p95 \(p95) ms")
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[1]))
    }
}
