import XCTest
import Darwin
@testable import WandKit

final class LineReaderTests: XCTestCase {
    private func withInput(_ data: Data, _ body: (Int32) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wand-line-test-\(UUID())")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        try body(fd)
    }

    func withPipe(_ body: (Int32, Int32) -> Void) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        body(fds[0], fds[1])
    }

    func testPipelinedUnicodeAndEmptyLines() {
        withPipe { input, output in
            let data = Data("cat 🐱\n\nsecond\n".utf8)
            data.withUnsafeBytes { _ = write(output, $0.baseAddress, $0.count) }
            let reader = LineReader(fd: input)
            XCTAssertEqual(reader.next(timeout: 1), "cat 🐱")
            XCTAssertEqual(reader.next(timeout: 1), "")
            XCTAssertEqual(reader.next(timeout: 1), "second")
        }
    }

    func testIncompleteAndOversizedFramesAreRejected() {
        withPipe { input, output in
            let data = Data("123456789\n".utf8)
            data.withUnsafeBytes { _ = write(output, $0.baseAddress, $0.count) }
            XCTAssertNil(LineReader(fd: input, maxBytes: 8).next(timeout: 1))
        }
        withPipe { input, output in
            _ = write(output, "partial", 7)
            XCTAssertNil(LineReader(fd: input).next(timeout: 0.03))
        }
    }

    func testIdlePeerHasBoundedDeadline() {
        withPipe { input, _ in
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertNil(LineReader(fd: input).next(timeout: 0.03))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        }
    }

    func testDelimiterAtEachReadBoundaryAndCompactionPreserveNextFrame() throws {
        for length in [16383, 16384, 16385, 32768] {
            let text = String(repeating: "x", count: length)
            try withInput(Data(("first\n" + text + "\nlast\n").utf8)) { fd in
                let reader = LineReader(fd: fd, maxBytes: length)
                XCTAssertEqual(reader.next(timeout: 1), "first")
                XCTAssertEqual(reader.next(timeout: 1), text)
                XCTAssertEqual(reader.next(timeout: 1), "last")
                XCTAssertNil(reader.next(timeout: 1))
            }
        }
    }

    func testExactFrameLimitAcceptsAndOneByteOverRejectsAcrossReads() throws {
        for length in [16384, 16385] {
            try withInput(Data((String(repeating: "x", count: length) + "\n").utf8)) { fd in
                let result = LineReader(fd: fd, maxBytes: 16384).next(timeout: 1)
                if length == 16384 { XCTAssertEqual(result?.utf8.count, 16384) }
                else { XCTAssertNil(result) }
            }
        }
    }

    func testFragmentedUnicodeSurvivesPartialReadTimeouts() {
        withPipe { input, output in
            let expected = String(repeating: "🐱盆栽", count: 64)
            let bytes = Data(expected.utf8)
            let reader = LineReader(fd: input)
            for offset in stride(from: 0, to: bytes.count, by: 31) {
                let piece = bytes[offset..<min(offset + 31, bytes.count)]
                piece.withUnsafeBytes { XCTAssertEqual(write(output, $0.baseAddress, $0.count), $0.count) }
                XCTAssertNil(reader.next(timeout: 0.001))
            }
            _ = write(output, "\n", 1)
            XCTAssertEqual(reader.next(timeout: 1), expected)
        }
    }

    func testCancellationDoesNotConsumeAlreadyBufferedNextFrame() {
        withPipe { input, output in
            _ = write(output, "first\nsecond\n", 13)
            let reader = LineReader(fd: input)
            XCTAssertEqual(reader.next(timeout: 1), "first")
            XCTAssertNil(reader.next(timeout: 1, cancelled: { true }))
            XCTAssertEqual(reader.next(timeout: 1), "second")
        }
    }

    func testEmbeddedNullInvalidUTF8AndPartialEOF() throws {
        try withInput(Data([0, 97, 10, 255, 10])) { fd in
            let reader = LineReader(fd: fd)
            XCTAssertEqual(reader.next(timeout: 1), "\0a")
            XCTAssertNil(reader.next(timeout: 1), "invalid UTF-8 must not become an accepted frame")
        }
        try withInput(Data("first\npartial".utf8)) { fd in
            let reader = LineReader(fd: fd)
            XCTAssertEqual(reader.next(timeout: 1), "first")
            XCTAssertNil(reader.next(timeout: 1), "EOF without newline is not a complete frame")
        }
    }

    func testManyCoalescedUnicodeFramesRetainOrderAndEmptyLines() throws {
        let expected = (0..<1000).map { $0 % 7 == 0 ? "" : "\($0):" + String(repeating: "盆栽🐱", count: $0 % 17) }
        try withInput(Data((expected.joined(separator: "\n") + "\n").utf8)) { fd in
            let reader = LineReader(fd: fd)
            for line in expected { XCTAssertEqual(reader.next(timeout: 1), line) }
            XCTAssertNil(reader.next(timeout: 1))
        }
    }
}
