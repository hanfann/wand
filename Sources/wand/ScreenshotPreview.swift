import Foundation
import CoreGraphics
import ImageIO
import WandKit

enum ScreenshotPreview {
    struct Result {
        let fullPath: String, previewPath: String
        let fullWidth: Int, fullHeight: Int, width: Int, height: Int
        let crop: CGRect
        let xOffset: Double, yOffset: Double, xScale: Double, yScale: Double

        var metadata: [String: Any] {
            [
                "full": fullPath, "preview": previewPath,
                "fullPixels": [fullWidth, fullHeight], "previewPixels": [width, height],
                "cropPixels": [Int(crop.minX), Int(crop.minY), Int(crop.width), Int(crop.height)],
                "previewPixelToPoint": ["xOffset": xOffset, "yOffset": yOffset, "xScale": xScale, "yScale": yScale]
            ]
        }

        func description() throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }

    // Derive from the saved capture, never a second framebuffer read. The original
    // remains full resolution; only this explicit preview path incurs decoding.
    static func make(path: String, pointSize: CGSize, options: ScreenshotOptions) throws -> Result {
        guard let edge = options.maxEdge,
              pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw failure("could not read full capture or point geometry")
        }
        let fullWidth = image.width, fullHeight = image.height
        let rect = options.crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard rect.maxX <= CGFloat(fullWidth), rect.maxY <= CGFloat(fullHeight) else {
            throw failure("crop exceeds full capture bounds; full capture retained at \(path)")
        }
        let factor = min(1, CGFloat(edge) / max(rect.width, rect.height))
        let width = max(1, Int((rect.width * factor).rounded()))
        let height = max(1, Int((rect.height * factor).rounded()))
        let unchanged = rect == CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight) && width == fullWidth && height == fullHeight
        let previewPath = unchanged ? path : URL(fileURLWithPath: path).deletingPathExtension().path + ".preview.png"
        if !unchanged {
            guard URL(fileURLWithPath: previewPath).resolvingSymlinksInPath().standardizedFileURL != URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL else {
                throw failure("preview destination aliases the full capture")
            }
            guard let cropped = image.cropping(to: rect),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw failure("could not allocate preview")
            }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let preview = context.makeImage() else { throw failure("could not render preview") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                throw failure("could not encode preview")
            }
            CGImageDestinationAddImage(destination, preview, nil)
            guard CGImageDestinationFinalize(destination) else { throw failure("could not finish preview") }
            try (data as Data).write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        }
        return Result(fullPath: path, previewPath: previewPath, fullWidth: fullWidth, fullHeight: fullHeight,
                      width: width, height: height, crop: rect,
                      xOffset: rect.minX * pointSize.width / CGFloat(fullWidth),
                      yOffset: rect.minY * pointSize.height / CGFloat(fullHeight),
                      xScale: rect.width * pointSize.width / CGFloat(width * fullWidth),
                      yScale: rect.height * pointSize.height / CGFloat(height * fullHeight))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "wand.preview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
