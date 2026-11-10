import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import WandKit

/// Explicit caller-owned visual baseline. No daemon-global image cache: another
/// agent cannot make a first-time observation look unchanged to this caller.
enum ScreenshotObservation {
    static func capture(path: String, scope: String, options: ScreenshotOptions,
                        capture: (String) throws -> CGSize) throws -> String {
        // Never infer visual equality from a stale saved image or a coarse settle
        // fingerprint. A failed fresh capture must fail the entire observation.
        let pointSize = try capture(path)
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width > 0, pointSize.height > 0 else {
            throw NSError(domain: "wand.screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid point geometry"])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              options.crop.map({ $0.x + $0.width <= width && $0.y + $0.height <= height }) ?? true else {
            throw NSError(domain: "wand.screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "invalid capture or crop bounds; full capture retained at \(path)"])
        }
        var identity: [String: Any] = ["version": 1, "device": scope,
                                       "points": [pointSize.width, pointSize.height]]
        if let edge = options.maxEdge { identity["preview"] = edge }
        if let crop = options.crop { identity["crop"] = [crop.x, crop.y, crop.width, crop.height] }
        var digest = SHA256()
        digest.update(data: try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
        digest.update(data: Data([0]))
        digest.update(data: data)
        let token = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let changed = token != options.since
        var result: [String: Any] = ["changed": changed, "token": token, "full": path]
        if changed {
            if options.maxEdge != nil {
                let preview = try ScreenshotPreview.make(path: path, pointSize: pointSize, options: options)
                result.merge(preview.metadata) { _, new in new }
            } else {
                result["image"] = path
                result["fullPixels"] = [width, height]
                result["pixelToPoint"] = ["xScale": pointSize.width / CGFloat(width),
                                          "yScale": pointSize.height / CGFloat(height)]
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
