import Foundation
import XCTest
import CoreGraphics
import ImageIO
import WandKit
@testable import wand

final class ScreenshotPreviewTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-preview-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(width: Int, height: Int) throws -> String {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)]
                for c in 0..<4 { pixels[(y * width + x) * 4 + c] = color[c] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let path = directory.appendingPathComponent("full.png").path
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return path
    }

    private func pixel(_ path: String, x: Int, y: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { bytes[(y * image.width + x) * 4 + $0] }
    }

    func testPortraitAndLandscapeResizePreserveOrientationAndFullCapture() throws {
        for (width, height) in [(300, 600), (600, 300)] {
            let path = try fixture(width: width, height: height)
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            let result = try ScreenshotPreview.make(path: path, pointSize: CGSize(width: width / 3, height: height / 3),
                                                    options: ScreenshotOptions(arguments: ["--preview", "150"]))
            XCTAssertEqual(result.width, width / 4)
            XCTAssertEqual(result.height, height / 4)
            XCTAssertEqual(result.xScale, 4.0 / 3.0, accuracy: 0.000001)
            XCTAssertEqual(result.yScale, 4.0 / 3.0, accuracy: 0.000001)
            XCTAssertEqual(try pixel(result.previewPath, x: 5, y: 5), [255, 0, 0, 255])
            XCTAssertEqual(try pixel(result.previewPath, x: result.width - 5, y: result.height - 5), [255, 255, 0, 255])
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        }
    }

    func testTopRightCropHasCorrectPixelsAndPointOffset() throws {
        let path = try fixture(width: 400, height: 400)
        let result = try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 200, height: 200),
                                                options: ScreenshotOptions(arguments: ["--preview", "100", "--crop", "200", "0", "200", "200"]))
        XCTAssertEqual([result.width, result.height], [100, 100])
        XCTAssertEqual(try pixel(result.previewPath, x: 50, y: 50), [0, 255, 0, 255])
        XCTAssertEqual(result.xOffset, 100)
        XCTAssertEqual(result.yOffset, 0)
        XCTAssertEqual(result.xOffset + 50 * result.xScale, 150)
        XCTAssertEqual(result.yOffset + 50 * result.yScale, 50)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.description().utf8)) as? [String: Any])
        XCTAssertEqual(json["cropPixels"] as? [Int], [200, 0, 200, 200])
    }

    func testSmallImageIsNotUpscaledOrDuplicated() throws {
        let path = try fixture(width: 324, height: 394)
        let result = try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 162, height: 197),
                                                options: ScreenshotOptions(arguments: ["--preview", "640"]))
        XCTAssertEqual(result.previewPath, path)
        XCTAssertEqual([result.width, result.height], [324, 394])
        XCTAssertEqual(result.xScale, 0.5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["full.png"])
    }

    func testInvalidCropAndGeometryLeaveFullCaptureIntact() throws {
        let path = try fixture(width: 100, height: 100)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 50, height: 50),
                                                        options: ScreenshotOptions(arguments: ["--preview", "50", "--crop", "90", "0", "20", "20"])))
        XCTAssertThrowsError(try ScreenshotPreview.make(path: path, pointSize: .zero,
                                                        options: ScreenshotOptions(arguments: ["--preview", "50"])))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["full.png"])
    }

    func testPreviewSymlinkCannotOverwriteOriginal() throws {
        let path = try fixture(width: 100, height: 100)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("full.preview.png").path, withDestinationPath: path)
        XCTAssertThrowsError(try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 50, height: 50),
                                                        options: ScreenshotOptions(arguments: ["--preview", "50"])))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testRoundedDimensionsHaveIndependentExactPointMapping() throws {
        let path = try fixture(width: 301, height: 601)
        let result = try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 150.5, height: 300.5),
                                                options: ScreenshotOptions(arguments: ["--preview", "200"]))
        XCTAssertEqual([result.width, result.height], [100, 200])
        XCTAssertEqual(Double(result.width) * result.xScale, 150.5, accuracy: 0.000001)
        XCTAssertEqual(Double(result.height) * result.yScale, 300.5, accuracy: 0.000001)
    }

    func testExistingIPadCaptureProducesBoundedPreview() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("docs/validation/reliability-2026-11-10/ipad-final/type.png")
        let path = directory.appendingPathComponent("ipad.png").path
        let original = try Data(contentsOf: fixture)
        try original.write(to: URL(fileURLWithPath: path))
        let result = try ScreenshotPreview.make(path: path, pointSize: CGSize(width: 1158, height: 756),
                                                options: ScreenshotOptions(arguments: ["--preview", "640"]))
        XCTAssertEqual([result.width, result.height], [640, 418])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        let preview = try Data(contentsOf: URL(fileURLWithPath: result.previewPath))
        XCTAssertLessThan(Double(preview.count) / Double(original.count), 0.3, "require at least 70% fewer PNG bytes for the saved iPad fixture")
        print("iPad preview: \(result.fullWidth)x\(result.fullHeight) -> \(result.width)x\(result.height); \(original.count) -> \(preview.count) PNG bytes")
        if let audit = ProcessInfo.processInfo.environment["WAND_PREVIEW_AUDIT_DIR"] {
            let folder = URL(fileURLWithPath: audit)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try preview.write(to: folder.appendingPathComponent("ipad.preview.png"))
            try result.description().write(to: folder.appendingPathComponent("mapping.json"), atomically: true, encoding: .utf8)
        }
    }
}
