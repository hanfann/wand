// Compile once before benchmarking: swiftc image-samples.swift -o /tmp/image-samples
// Native PNG decoding avoids a Python image dependency. Region is normalized 0–1.
import AppKit
import Foundation

var results: [[String: Any]] = []
var arguments = Array(CommandLine.arguments.dropFirst())
var region = [0.0, 0.0, 1.0, 1.0]
if arguments.first == "--region" {
    guard arguments.count >= 6 else { fatalError("--region x y width height PNG...") }
    region = arguments[1...4].map { Double($0) ?? .nan }
    guard region.allSatisfy({ $0.isFinite && $0 >= 0 }), region[2] > 0, region[3] > 0,
          region[0] + region[2] <= 1, region[1] + region[3] <= 1 else { fatalError("invalid region") }
    arguments.removeFirst(5)
}
for path in arguments {
    guard let data = FileManager.default.contents(atPath: path),
          let bitmap = NSBitmapImageRep(data: data) else { fatalError("invalid PNG: \(path)") }
    var samples: [Double] = []
    for row in 0..<24 { for column in 0..<32 {
        let x = Int((region[0] + Double(column) / 32 * region[2]) * Double(bitmap.pixelsWide))
        let y = Int((region[1] + Double(row) / 24 * region[3]) * Double(bitmap.pixelsHigh))
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { fatalError("cannot decode pixel") }
        samples += [color.redComponent, color.greenComponent, color.blueComponent]
    }}
    results.append(["path": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                    "bytes": data.count, "samples": samples])
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
