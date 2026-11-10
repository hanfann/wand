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

    func testMissingExecutableFailsWithoutWaiting() {
        XCTAssertEqual(ProcessRunner.run("/nonexistent/wand-test", []).status, -1)
    }

    func testExitedParentCannotLeaveAnEndlessOutputDrain() {
        let start = ProcessInfo.processInfo.systemUptime
        let script = """
        import os, signal
        if os.fork(): os._exit(0)
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        signal.alarm(3)
        while True: os.write(1, b'x' * 16384)
        """
        let result = ProcessRunner.run("/usr/bin/python3", ["-c", script], timeout: 5, outputLimit: 256)
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertLessThan(result.output.utf8.count, 350)
    }
}
