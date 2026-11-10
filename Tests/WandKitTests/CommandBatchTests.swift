import XCTest
@testable import WandKit

final class CommandBatchTests: XCTestCase {
    func testPreservesOrderAndLiteralText() throws {
        let batch = try CommandBatch(json: ##"[["tap","42","90"],["type","line one\nline two"],["assert","#status","label=done"]]"##)
        XCTAssertEqual(batch.commands.count, 3)
        XCTAssertEqual(batch.commands[1], ["type", "line one\nline two"])
        XCTAssertEqual(batch.commands[2][0], "assert")
    }
    func testRejectsInvalidOrRecursiveSequencesBeforeExecution() {
        for invalid in ["[]", #"[["tap",42,90]]"#, #"[["tap","42","90"],[]]"#,
                        #"[["tap","42","90"],["stop"]]"#, #"[["batch","[]"]]"#,
                        #"[["tap","42","90"],["typo"]]"#] {
            XCTAssertThrowsError(try CommandBatch(json: invalid), invalid)
        }
    }
    func testBoundsLongSequences() throws {
        let data = try JSONSerialization.data(withJSONObject: Array(repeating: ["ping"], count: 65))
        XCTAssertThrowsError(try CommandBatch(json: String(decoding: data, as: UTF8.self)))
    }
}
