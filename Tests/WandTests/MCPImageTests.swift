import Foundation
import XCTest
import WandKit
@testable import wand

final class MCPImageTests: XCTestCase {
    private var directory: URL!
    private let token = String(repeating: "a", count: 64)
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-mcp-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func reply(path: String, preview: String? = nil, changed: Bool = true) throws -> String {
        var value: [String: Any] = ["full": path, "changed": changed, "token": token]
        if let preview { value["preview"] = preview }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testPreparationPreservesBatchAndRequiresExplicitFinalScreenshot() throws {
        let path = directory.appendingPathComponent("frame.png").path
        let request = try MCPImageRequest(command: ["batch", "--summary", #"[["tap","10","20"],["screenshot"]]"#], defaultPath: path)
        let batch = try CommandBatch(arguments: Array(request.command.dropFirst()))
        XCTAssertTrue(batch.summary)
        XCTAssertEqual(batch.commands, [["tap", "10", "20"], ["screenshot", path, "--preview", "640", "--since", "none"]])
        XCTAssertThrowsError(try MCPImageRequest(command: ["batch", #"[["tap","10","20"]]"#], defaultPath: path))
        XCTAssertThrowsError(try MCPImageRequest(command: ["batch", #"[["key","NaN"],["screenshot"]]"#], defaultPath: path))
    }

    func testAttachmentUsesActualPNGAndHandlesMultilineBatchText() throws {
        let path = directory.appendingPathComponent("frame\n2 OK path.png").path
        let request = try MCPImageRequest(command: ["batch", #"[["ui"],["screenshot"]]"#], defaultPath: path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = try Data(contentsOf: root.appendingPathComponent("docs/validation/workflow-profiling-2026-11-10/ocr-source.png"))
        try image.write(to: URL(fileURLWithPath: path))
        let text = "1 OK user label\n2 OK misleading earlier text\n2 OK " + (try reply(path: path, preview: path))
        let attachment = try XCTUnwrap(try request.attachment(reply: text))
        XCTAssertEqual(attachment["type"] as? String, "image")
        XCTAssertEqual(attachment["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(attachment["data"] as? String)), image)
    }

    func testUnchangedImageRequiresMatchingCallerTokenAndDoesNotReadFile() throws {
        let path = directory.appendingPathComponent("absent.png").path
        let request = try MCPImageRequest(command: ["screenshot", "--since", token], defaultPath: path)
        XCTAssertNil(try request.attachment(reply: reply(path: path, changed: false)))
        let fresh = try MCPImageRequest(command: ["screenshot"], defaultPath: path)
        XCTAssertThrowsError(try fresh.attachment(reply: reply(path: path, changed: false)))
    }

    func testUnexpectedPathsInvalidPNGAndOversizedPayloadFail() throws {
        let path = directory.appendingPathComponent("frame.png").path
        let request = try MCPImageRequest(command: ["screenshot"], defaultPath: path)
        XCTAssertThrowsError(try request.attachment(reply: reply(path: "/other.png", preview: "/other.png")))
        XCTAssertThrowsError(try request.attachment(reply: reply(path: path, preview: "/other.png")))
        for data in [Data("not PNG".utf8), Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
            try data.write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try request.attachment(reply: reply(path: path, preview: path)))
        }
    }
}
