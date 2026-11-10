import XCTest
import WandKit
@testable import wand

final class ProfilingTests: XCTestCase {
    func testProfilePreservesFailureExitAndNeverReplays() throws {
        var calls = 0
        let profile = PhaseProfile()
        let reply = Daemon.profileReply(profile: profile) {
            calls += 1
            return profile.measure("dispatch") {
                Daemon.Reply(ok: false, text: "partial input; inspect 🌱", exitAfterReply: true)
            }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.exitAfterReply)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["result"] as? String, "partial input; inspect 🌱")
        XCTAssertEqual(json["ok"] as? Bool, false)
        let metrics = try XCTUnwrap(json["profile"] as? [String: Any])
        XCTAssertEqual(metrics["result_bytes"] as? Int, "partial input; inspect 🌱".utf8.count)
        XCTAssertGreaterThanOrEqual(metrics["daemon_cpu_ms"] as? Double ?? -1, 0)
    }
}
