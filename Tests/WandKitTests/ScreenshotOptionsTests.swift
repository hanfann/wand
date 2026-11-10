import XCTest
@testable import WandKit

final class ScreenshotOptionsTests: XCTestCase {
    func testLegacyAndPreviewOptions() throws {
        XCTAssertNil(try ScreenshotOptions(arguments: []).maxEdge)
        XCTAssertEqual(try ScreenshotOptions(arguments: ["/tmp/a b.png"]).path, "/tmp/a b.png")
        let options = try ScreenshotOptions(arguments: ["--crop", "10", "20", "30", "40", "a.png", "--preview", "640"])
        XCTAssertEqual(options.path, "a.png")
        XCTAssertEqual(options.maxEdge, 640)
        XCTAssertEqual(options.crop?.x, 10)
        XCTAssertEqual(options.crop?.height, 40)
    }

    func testInvalidArgumentsFailDuringBatchPreflight() {
        for args in [["--preview"], ["--preview", "0"], ["--preview", "4097"], ["--preview", "NaN"],
                     ["--preview", "640.5"], ["--preview", "10", "--preview", "20"], ["a.png", "b.png"],
                     ["--crop", "0", "0", "10", "10"], ["--preview", "640", "--crop", "-1", "0", "10", "10"],
                     ["--preview", "640", "--crop", "0", "0", "0", "10"], ["--preview", "640", "--crop", "0"],
                     ["--typo"], [""]] {
            XCTAssertThrowsError(try CommandValidation.validate(["screenshot"] + args), "\(args)")
        }
        XCTAssertThrowsError(try CommandBatch(json: #"[["tap","10","20"],["screenshot","--preview","NaN"]]"#))
    }
}
