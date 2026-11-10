import XCTest
@testable import WandKit

final class OutputTailTests: XCTestCase {
    private func append(_ bytes: Data, to tail: inout OutputTail) {
        bytes.withUnsafeBytes { tail.append($0) }
    }

    func testEmptyExactLimitAndZeroOrNegativeLimits() {
        for limit in [-1, 0, 1, 16] {
            var tail = OutputTail(limit: limit)
            append(Data(), to: &tail)
            XCTAssertFalse(tail.truncated)
            let bytes = Data(repeating: 42, count: max(1, limit))
            append(bytes, to: &tail)
            XCTAssertEqual(tail.data, bytes.suffix(max(0, limit)))
            XCTAssertEqual(tail.truncated, limit <= 0)
            append(Data([43]), to: &tail)
            XCTAssertTrue(tail.truncated)
            XCTAssertLessThanOrEqual(tail.count, max(0, limit))
        }
    }

    func testPartialFillWrapAndLargeReplacementKeepExactTail() {
        var tail = OutputTail(limit: 7)
        var reference = Data()
        for chunk in ["abc", "def", "ghij", "k", "lmnopqrstu", "vw", "xyz"] {
            let bytes = Data(chunk.utf8)
            reference.append(bytes)
            append(bytes, to: &tail)
            XCTAssertEqual(tail.data, reference.suffix(7))
            XCTAssertEqual(tail.count, min(7, reference.count))
            XCTAssertEqual(tail.truncated, reference.count > 7)
        }
    }

    func testDeterministicChunkBoundariesMatchReferenceWithoutUnboundedRetention() {
        var seed: UInt64 = 42
        for limit in [0, 1, 17, 257, 4096] {
            var tail = OutputTail(limit: limit)
            var reference = Data()
            for _ in 0..<300 {
                seed = seed &* 6364136223846793005 &+ 1
                let length = Int(seed % 513)
                let chunk = Data((0..<length).map { UInt8(truncatingIfNeeded: seed &+ UInt64($0)) })
                reference.append(chunk)
                append(chunk, to: &tail)
                XCTAssertEqual(tail.data, reference.suffix(limit))
                XCTAssertLessThanOrEqual(tail.count, limit)
            }
        }
    }

    func testReturnedDataDoesNotMutateAndUTF8TailMatchesExistingDecoding() {
        var tail = OutputTail(limit: 9)
        append(Data("old".utf8), to: &tail)
        let snapshot = tail.data
        let text = Data("盆栽 🌱 hello".utf8)
        for byte in text { append(Data([byte]), to: &tail) }
        XCTAssertEqual(snapshot, Data("old".utf8))
        XCTAssertEqual(tail.data, text.suffix(9))
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), String(decoding: text.suffix(9), as: UTF8.self))
    }
}
