import XCTest
import Darwin
@testable import WandKit

final class WorkerProcessTests: XCTestCase {
    func testPersistentWorkerPreservesLargeUnicodeReplies() throws {
        let worker = WorkerProcess(executable: "/bin/cat", arguments: [])
        let text = String(repeating: "🐈漢字", count: 20000)
        XCTAssertEqual(try worker.request(["text": text], timeout: 2)["text"] as? String, text)
        let pid = worker.pid
        XCTAssertEqual(try worker.request(["sequence": 2], timeout: 2)["sequence"] as? Int, 2)
        XCTAssertEqual(worker.pid, pid)
        worker.stop()
    }
    func testStallIsBoundedAndChildDoesNotSurvive() {
        let worker = WorkerProcess(executable: "/bin/sleep", arguments: ["30"])
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try worker.request(["read": true], timeout: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertNil(worker.pid)
        // A new request would start a fresh worker, never replay the old message.
    }
    func testClosedWorkerFailsWithoutReplay() {
        let worker = WorkerProcess(executable: "/usr/bin/true", arguments: [])
        XCTAssertThrowsError(try worker.request(["set": "value"], timeout: 1))
        XCTAssertNil(worker.pid)
    }
    func testCancellationWakesWaitingReader() throws {
        let worker = WorkerProcess(executable: "/bin/sleep", arguments: ["30"])
        let token = CommandCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try worker.request(["read": true], timeout: 10, cancelled: { token.isCancelled }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertNil(worker.pid)
    }
    func testCancellationSeparatesQueuedAndDispatchedWork() {
        let queued = CommandCancellation(); queued.cancel()
        XCTAssertFalse(queued.beginDispatch()); XCTAssertFalse(queued.wasDispatched)
        let active = CommandCancellation(); XCTAssertTrue(active.beginDispatch()); active.cancel()
        XCTAssertTrue(active.wasDispatched); XCTAssertTrue(active.isCancelled)
    }
}
