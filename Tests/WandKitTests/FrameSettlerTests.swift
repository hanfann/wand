import XCTest
@testable import WandKit

final class FrameSettlerTests: XCTestCase {
    func testWatchDefersSamplesButKeepsMinimumAndThreeStableReads() {
        var time = 0.0, samples: [Double] = [], pauses: [Double] = []
        let outcome = FrameSettler.run(minimum: 1, maximum: 1.5, now: { time }, pause: {
            pauses.append($0); time += $0
        }, cancelled: { false }, fingerprint: { samples.append(time); return 42 })
        XCTAssertEqual(outcome, .stable)
        XCTAssertGreaterThanOrEqual(time, 1)
        XCTAssertLessThan(time, 1.1)
        XCTAssertEqual(samples.count, 3)
        XCTAssertGreaterThanOrEqual(samples[0], 0.82 - 0.000001)
        XCTAssertTrue(pauses.allSatisfy { $0 <= 0.09 })
    }

    func testAnimationChangingLateMustEstablishFreshStability() {
        var time = 0.0, samples = 0
        let outcome = FrameSettler.run(minimum: 1, maximum: 1.5, now: { time }, pause: { time += $0 },
                                      cancelled: { false }, fingerprint: {
            samples += 1
            return samples < 3 ? 1 : 2
        })
        XCTAssertEqual(outcome, .stable)
        XCTAssertEqual(samples, 5)
        XCTAssertGreaterThanOrEqual(time, 1.18 - 0.000001)
    }

    func testCancelledDuringDeferredPeriodDoesNotCapture() {
        var time = 0.0, samples = 0
        let outcome = FrameSettler.run(minimum: 1, maximum: 1.5, now: { time }, pause: { time += $0 },
                                      cancelled: { time >= 0.2 }, fingerprint: { samples += 1; return 1 })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(samples, 0)
        XCTAssertLessThan(time, 0.3)
    }

    func testChangingFramesStopAtDeadlineAndUnavailableFrameStops() {
        var time = 0.0, signature: UInt64 = 0
        let outcome = FrameSettler.run(minimum: 1, maximum: 1.5, now: { time }, pause: { time += $0 },
                                      cancelled: { false }, fingerprint: { signature += 1; return signature })
        XCTAssertEqual(outcome, .deadline)
        XCTAssertEqual(time, 1.5, accuracy: 0.000001)
        XCTAssertEqual(FrameSettler.run(minimum: 0.18, maximum: 1.5, now: { time }, pause: { time += $0 },
                                       cancelled: { false }, fingerprint: { 0 }), .unavailable)
    }

    func testPhoneStillSamplesImmediatelyAndWaitsForThreeReads() {
        var time = 0.0, samples: [Double] = []
        let outcome = FrameSettler.run(minimum: 0.18, maximum: 1.5, now: { time }, pause: { time += $0 },
                                      cancelled: { false }, fingerprint: { samples.append(time); return 1 })
        XCTAssertEqual(outcome, .stable)
        XCTAssertEqual(samples, [0, 0.09, 0.18])
    }
}
