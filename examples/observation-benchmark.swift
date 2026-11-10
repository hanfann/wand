// Compile via observation-benchmark.py; replays saved frames, never boots a simulator.
import Foundation
import CoreGraphics
import CryptoKit

@main enum Benchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, let width = Double(args[2]), let height = Double(args[3]) else { exit(64) }
        let original = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let path = URL(fileURLWithPath: args[4]).appendingPathComponent("frame.png").path
        let size = CGSize(width: width, height: height)
        let previewOptions = try ScreenshotOptions(arguments: ["--preview", "640"])
        var captures = 0
        func capture(_ destination: String) throws -> CGSize {
            captures += 1
            try original.write(to: URL(fileURLWithPath: destination))
            return size
        }
        func observe(_ since: String) throws -> String {
            try ScreenshotObservation.capture(path: path, scope: "benchmark-device",
                options: ScreenshotOptions(arguments: ["--preview", "640", "--since", since]), capture: capture)
        }
        func decode(_ response: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
        }
        let seed = try decode(observe("none"))
        let token = seed["token"] as! String
        let previewPath = seed["preview"] as! String
        let previewBytes = try Data(contentsOf: URL(fileURLWithPath: previewPath))
        var samples: [String: [Double]] = ["legacy_preview": [], "unchanged": [], "forced_refresh": []]
        var responseBytes: [String: Int] = [:]
        let modes = ["legacy_preview", "unchanged", "forced_refresh"]
        for index in -3..<30 {
            let offset = (index + 3) % modes.count
            let order = Array(modes[offset...] + modes[..<offset])
            for mode in order {
                try autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let response: String
                    if mode == "legacy_preview" {
                        _ = try capture(path)
                        response = try ScreenshotPreview.make(path: path, pointSize: size, options: previewOptions).description()
                    } else {
                        response = try observe(mode == "unchanged" ? token : "none")
                    }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    if index >= 0 { samples[mode]!.append(elapsed) }
                    responseBytes[mode] = response.utf8.count
                    let value = try decode(response)
                    if mode == "unchanged" {
                        precondition(value["changed"] as? Bool == false && value["preview"] == nil)
                    } else {
                        let delivered = value["preview"] as! String
                        let deliveredData = try Data(contentsOf: URL(fileURLWithPath: delivered))
                        precondition(deliveredData == previewBytes)
                    }
                    let fullData = try Data(contentsOf: URL(fileURLWithPath: path))
                    precondition(fullData == original)
                }
            }
        }
        // A separate 20-observation sequence counts real requested image deliveries.
        var since = "none", deliveries = 0
        let before = captures
        for _ in 0..<20 {
            let value = try decode(observe(since))
            since = value["token"] as! String
            if value["preview"] != nil { deliveries += 1 }
        }
        precondition(deliveries == 1 && captures - before == 20)
        var summary: [String: Any] = [:]
        for (mode, values) in samples {
            let ordered = values.sorted()
            summary[mode] = ["n": ordered.count, "median_ms": ordered[ordered.count / 2],
                "p95_ms": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1],
                "max_ms": ordered.last!, "response_bytes": responseBytes[mode]!]
        }
        let output: [String: Any] = ["samples_ms": samples, "summary": summary,
            "sequence": ["captures": 20, "legacy_image_deliveries": 20, "conditional_image_deliveries": deliveries,
                         "legacy_image_bytes": 20 * previewBytes.count, "conditional_image_bytes": deliveries * previewBytes.count],
            "original_sha256": SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            "note": "Saved-frame replay includes file write/response preparation; excludes simulator acquisition/encoding and model image processing."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
