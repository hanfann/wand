import XCTest
import Darwin
@testable import WandKit

final class LineReaderTests: XCTestCase {
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
}
