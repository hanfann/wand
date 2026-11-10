import XCTest
@testable import WandKit

final class OCRTargetTests: XCTestCase {
    private func observation(_ text: String, x: Double = 10, confidence: Double = 0.9) -> [String: Any] {
        ["text": text, "x": x, "y": 20.0, "w": 40.0, "h": 10.0, "conf": confidence]
    }
    func testExactWinsOverSubstring() throws {
        let match = try OCRTarget.resolve("Save", observations: [observation("Save draft"), observation("SAVE")], width: 100, height: 100)
        XCTAssertEqual(match?.text, "SAVE"); XCTAssertEqual(match?.x, 30); XCTAssertEqual(match?.y, 25)
    }
    func testDuplicateAndSubstringAmbiguityRefuseInput() {
        for labels in [["Save", "Save"], ["Save draft", "Save photo"]] {
            XCTAssertThrowsError(try OCRTarget.resolve("Save", observations: labels.map { observation($0) }, width: 100, height: 100))
        }
    }
    func testUncertainAndUnsafeGeometryRefuseInput() {
        for hit in [observation("Save", confidence: 0.2), observation("Save", x: -.infinity), observation("Save", x: 90)] {
            XCTAssertThrowsError(try OCRTarget.resolve("Save", observations: [hit], width: 100, height: 100))
        }
        XCTAssertThrowsError(try OCRTarget.resolve(" ", observations: [], width: 100, height: 100))
    }
    func testMissingTargetDoesNotSelectAnotherLabel() throws {
        XCTAssertNil(try OCRTarget.resolve("Delete", observations: [observation("Save")], width: 100, height: 100))
    }
}
