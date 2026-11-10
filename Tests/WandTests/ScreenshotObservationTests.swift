import Foundation
import XCTest
import CoreGraphics
import ImageIO
import WandKit
@testable import wand

final class ScreenshotObservationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-observation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(changedPixel: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        if changedPixel {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func observe(_ data: Data, since: String = "none", scope: String = "device-a",
                         size: CGSize = CGSize(width: 64, height: 64),
                         extra: [String] = [], name: String = "frame.png") throws -> [String: Any] {
        let path = directory.appendingPathComponent(name).path
        let response = try ScreenshotObservation.capture(path: path, scope: scope,
            options: ScreenshotOptions(arguments: ["--since", since] + extra)) { path in
                try data.write(to: URL(fileURLWithPath: path))
                return size
            }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func testCallerOwnsBaselineAndEveryRequestCapturesFresh() throws {
        let data = try fixture()
        let first = try observe(data)
        let token = try XCTUnwrap(first["token"] as? String)
        XCTAssertEqual(first["changed"] as? Bool, true)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(first["fullPixels"] as? [Int], [128, 128])
        XCTAssertEqual((first["pixelToPoint"] as? [String: Double])?["xScale"], 0.5)
        let nextPath = directory.appendingPathComponent("next.png").path
        var captures = 0
        let reply = try ScreenshotObservation.capture(path: nextPath,
            scope: "device-a", options: ScreenshotOptions(arguments: ["--since", token])) { path in
                captures += 1
                try data.write(to: URL(fileURLWithPath: path))
                return CGSize(width: 64, height: 64)
            }
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(next["changed"] as? Bool, false)
        XCTAssertNil(next["image"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nextPath)), data)
        // Another caller with no retained image must get a full observation.
        XCTAssertEqual(try observe(data)["changed"] as? Bool, true)
    }

    func testPixelGeometryDeviceAndPresentationChangesInvalidateToken() throws {
        let data = try fixture()
        let token = try XCTUnwrap(try observe(data)["token"] as? String)
        XCTAssertEqual(try observe(fixture(changedPixel: true), since: token)["changed"] as? Bool, true)
        XCTAssertEqual(try observe(data, since: token, scope: "device-b")["changed"] as? Bool, true)
        XCTAssertEqual(try observe(data, since: token, size: CGSize(width: 128, height: 128))["changed"] as? Bool, true)
        XCTAssertEqual(try observe(data, since: token, extra: ["--preview", "64"])["changed"] as? Bool, true)
    }

    func testUnchangedCaptureSkipsPreviewButForceRefreshRegeneratesIt() throws {
        let data = try fixture()
        let options = ["--preview", "64"]
        let first = try observe(data, extra: options)
        let token = try XCTUnwrap(first["token"] as? String)
        let preview = try XCTUnwrap(first["preview"] as? String)
        try FileManager.default.removeItem(atPath: preview)
        let next = try observe(data, since: token, extra: options)
        XCTAssertEqual(next["changed"] as? Bool, false)
        XCTAssertNil(next["preview"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview))
        XCTAssertEqual(try observe(data, since: "none", extra: options)["changed"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview))
        XCTAssertEqual(try observe(data, since: token, extra: options + ["--crop", "0", "0", "64", "64"])["changed"] as? Bool, true)
    }

    func testCaptureFailureCannotClaimUnchangedFromOldFile() throws {
        let token = try XCTUnwrap(try observe(fixture())["token"] as? String)
        XCTAssertThrowsError(try ScreenshotObservation.capture(path: directory.appendingPathComponent("frame.png").path,
            scope: "device-a",
            options: ScreenshotOptions(arguments: ["--since", token])) { _ in throw CocoaError(.fileReadUnknown) })
    }

    func testInvalidDataGeometryAndCropFail() throws {
        XCTAssertThrowsError(try observe(Data("not a PNG".utf8)))
        XCTAssertThrowsError(try observe(fixture(), size: .zero))
        XCTAssertThrowsError(try observe(fixture(), extra: ["--preview", "64", "--crop", "120", "0", "20", "20"]))
    }
}
