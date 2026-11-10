import XCTest
@testable import WandKit

final class ProcessRunnerTests: XCTestCase {
    func testDrainsOutputLargerThanPipeCapacity() {
        let result = ProcessRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"abcdefghij\" }"], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 220_000)
    }

    func testDeadlineTerminatesAndReapsChild() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.05)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.output.contains("may have applied"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    func testRetainsBoundedDiagnosticTailAndExitStatus() {
        let result = ProcessRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"abcdefghij\"; print \"END\"; exit 7 }"], outputLimit: 256)
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.hasSuffix("END\n"))
        XCTAssertTrue(result.output.contains("truncated"))
        XCTAssertLessThan(result.output.utf8.count, 350)
    }

    func testRepeatedOverflowRetainsExactUnicodeTailAndExitStatus() {
        let script = "import os; data=('prefix-盆栽🌱\\n'*10000).encode(); os.write(1,data); os.write(1,b'END\\n'); raise SystemExit(7)"
        let result = ProcessRunner.run("/usr/bin/python3", ["-c", script], timeout: 3, outputLimit: 1003)
        let expected = Data((String(repeating: "prefix-盆栽🌱\n", count: 10000) + "END\n").utf8).suffix(1003)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "[output truncated to last 1003 bytes]\n" + String(decoding: expected, as: UTF8.self))
    }

    func testZeroLimitStillDrainsAndReportsTruncation() {
        let result = ProcessRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"output\"; exit 9 }"], timeout: 3, outputLimit: 0)
        XCTAssertEqual(result.status, 9)
        XCTAssertEqual(result.output, "[output truncated to last 0 bytes]\n")
    }

    func testContinuouslyOverflowingChildStillHonorsDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = ProcessRunner.run("/usr/bin/yes", ["output"], timeout: 0.05, outputLimit: 257)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        XCTAssertTrue(result.output.hasPrefix("[output truncated to last 257 bytes]\n"))
        XCTAssertTrue(result.output.contains("operation may have applied"))
        XCTAssertLessThan(result.output.utf8.count, 512)
    }

    func testMissingExecutableFailsWithoutWaiting() {
        XCTAssertEqual(ProcessRunner.run("/nonexistent/wand-test", []).status, -1)
    }

    func testExitedParentCannotLeaveAnEndlessOutputDrain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-drain-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = directory.appendingPathComponent("emitter").path
        let build = ProcessRunner.run("/usr/bin/clang", [root.appendingPathComponent("examples/process-output-emitter.c").path,
                                                        "-O2", "-o", executable], timeout: 30)
        XCTAssertEqual(build.status, 0, build.output)
        guard build.status == 0 else { return }
        // Exclude fixture compilation/interpreter startup. The native fixture's
        // handshake guarantees output has started before its parent exits.
        let start = ProcessInfo.processInfo.systemUptime
        let result = ProcessRunner.run(executable, ["--orphan-writer"], timeout: 5, outputLimit: 256)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("truncated"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertLessThan(result.output.utf8.count, 350)
    }
}
