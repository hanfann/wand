import Foundation
import XCTest
import WandKit
@testable import wand

final class BatchExecutionTests: XCTestCase {
    private func batch(summary: Bool) throws -> CommandBatch {
        try CommandBatch(json: #"[["tap","10","20"],["tap","30","40"],["ui","diff"]]"#, summary: summary)
    }

    func testSummaryExecutesEveryStepAndPreservesFinalUnicodeObservation() throws {
        let batch = try batch(summary: true)
        var received: [[String]] = []
        let observation = "2 elements\ne1 text \"盆栽 🌱\"\n- e2 button \"Save\""
        let reply = Daemon.executeBatch(batch, cancelled: { false }) { command in
            received.append(command)
            return Daemon.Reply(ok: true, text: command[0] == "ui" ? observation : "tapped")
        }
        XCTAssertEqual(received, batch.commands)
        XCTAssertTrue(reply.ok)
        XCTAssertFalse(reply.exitAfterReply)
        XCTAssertEqual(reply.text, "completed 3/3\n3 OK " + observation)
    }

    func testDefaultRetainsEveryStepWithoutChangingFormat() throws {
        var step = 0
        let reply = Daemon.executeBatch(try batch(summary: false), cancelled: { false }) { _ in
            step += 1
            return Daemon.Reply(ok: true, text: "result \(step)")
        }
        XCTAssertEqual(reply.text, "1 OK result 1\n2 OK result 2\n3 OK result 3")
    }

    func testFailureAtAnyStepStopsWithoutReplayAndPreservesErrorAndExit() throws {
        for summary in [false, true] {
            for failedIndex in 0..<3 {
                var calls = 0
                let detail = "uncertain delivery\ninspect before retrying 🌱"
                let reply = Daemon.executeBatch(try batch(summary: summary), cancelled: { false }) { _ in
                    defer { calls += 1 }
                    return Daemon.Reply(ok: calls != failedIndex, text: calls == failedIndex ? detail : "tapped",
                                        exitAfterReply: calls == failedIndex)
                }
                XCTAssertEqual(calls, failedIndex + 1)
                XCTAssertFalse(reply.ok)
                XCTAssertTrue(reply.exitAfterReply)
                XCTAssertTrue(reply.text.contains("\(failedIndex + 1) FAIL " + detail))
                XCTAssertTrue(reply.text.hasSuffix("stopped; remaining commands did not run. Inspect state before retrying"))
                if summary {
                    XCTAssertTrue(reply.text.hasPrefix("completed \(failedIndex)/3\n"))
                    XCTAssertFalse(reply.text.contains("tapped"))
                }
            }
        }
    }

    func testCancellationBeforeOrDuringBatchSendsNoRemainingCommands() throws {
        for summary in [false, true] {
            for completed in 0..<3 {
                var calls = 0
                let reply = Daemon.executeBatch(try batch(summary: summary), cancelled: { calls == completed }) { _ in
                    calls += 1
                    return Daemon.Reply(ok: true, text: "tapped")
                }
                XCTAssertEqual(calls, completed)
                XCTAssertFalse(reply.ok)
                XCTAssertTrue(reply.text.contains("remaining batch steps did not run; prior steps may have applied"))
                if summary { XCTAssertTrue(reply.text.hasPrefix("completed \(completed)/3\n")) }
            }
        }
    }

    func testSingleStepSummaryRetainsEntireResult() throws {
        let batch = try CommandBatch(json: #"[["screenshot","/tmp/capture.png"]]"#, summary: true)
        let reply = Daemon.executeBatch(batch, cancelled: { false }) { _ in
            Daemon.Reply(ok: true, text: "/tmp/capture.png")
        }
        XCTAssertEqual(reply.text, "completed 1/1\n1 OK /tmp/capture.png")
    }

    func testRepresentativeLongBatchCutsResponseBytesWithoutChangingExecution() throws {
        let commands = Array(repeating: ["tap", "40", "80"], count: 31) + [["ui", "diff"]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: commands), as: UTF8.self)
        var counts: [Int] = [], replies: [String] = []
        for summary in [false, true] {
            var calls = 0
            let reply = Daemon.executeBatch(try CommandBatch(json: json, summary: summary), cancelled: { false }) { command in
                calls += 1
                return Daemon.Reply(ok: true, text: command[0] == "ui" ? "+ e1 text \"Ready\" @50,60" : "tapped @40,80")
            }
            XCTAssertTrue(reply.ok)
            counts.append(calls)
            replies.append(reply.text)
        }
        XCTAssertEqual(counts, [32, 32])
        let sizes = replies.map { $0.utf8.count }
        XCTAssertLessThan(Double(sizes[1]) / Double(sizes[0]), 0.2, "require at least 80% fewer response bytes for this fixture")
        print("Batch fixture: \(sizes[0]) -> \(sizes[1]) UTF-8 bytes; 32 commands executed in each mode")
    }
}
