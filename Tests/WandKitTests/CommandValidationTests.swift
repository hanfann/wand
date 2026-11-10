import XCTest
@testable import WandKit

final class CommandValidationTests: XCTestCase {
    func testRejectsNonfiniteMalformedAndUnboundedInput() {
        for command in [["tap", "nan", "30"], ["swipe", "0", "0", "oops", "10"],
                        ["key", "inf"], ["key", "4.5"], ["longpress", "20", "30", "-1"],
                        ["crown", "down", "100000000"], ["scroll", "sideways"],
                        ["wait", "Save", "inf"], ["pinch", "Save", "0"],
                        ["assert", "Save", "typo"], ["tap", ""], ["tapocr", " "], ["tap", "#"]] {
            XCTAssertThrowsError(try CommandValidation.validate(command), "\(command)")
        }
    }
    func testValidSelectorsCoordinatesAndIntegralJSONNumbers() throws {
        for command in [["tap", "Save changes"], ["tap", "20.5", "30"],
                        ["key", "42.0"], ["crown", "down", "2.0"],
                        ["longpress", "#save", "0.5"], ["rotate", "Save", "-0.5"],
                        ["setvalue", "#field", ""], ["type", "NaN"], ["wait", "Save", "0"]] {
            XCTAssertNoThrow(try CommandValidation.validate(command), "\(command)")
        }
    }
    func testInvalidLaterBatchStepPreventsAnyDispatch() {
        XCTAssertThrowsError(try CommandBatch(json: "[[\"tap\",\"20\",\"30\"],[\"key\",\"nan\"]]"))
    }
    func testTypingNeverSilentlyDropsUnsupportedText() throws {
        try CommandValidation.validate(["type", String((32...126).compactMap(UnicodeScalar.init).map(Character.init))])
        for command in [["type", "hello🐈"], ["typein", "#field", "漢字"]] {
            XCTAssertThrowsError(try CommandValidation.validate(command))
        }
        try CommandValidation.validate(["setvalue", "#field", "漢字🐈"])
    }
}
