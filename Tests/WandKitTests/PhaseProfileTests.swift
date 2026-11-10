import XCTest
@testable import WandKit

final class PhaseProfileTests: XCTestCase {
    func testNestedTimesPartitionInsteadOfDoubleCounting() {
        var time = 0.0
        let profile = PhaseProfile(clock: { time })
        profile.measure("dispatch") {
            time += 0.01
            profile.measure("settle") {
                time += 0.02
                profile.measure("frame_fingerprint") { time += 0.03 }
                time += 0.04
            }
            time += 0.05
        }
        XCTAssertEqual(profile.elapsedMs, 150, accuracy: 0.000001)
        XCTAssertEqual(profile.phases["dispatch"]!.exclusiveMs, 60, accuracy: 0.000001)
        XCTAssertEqual(profile.phases["settle"]!.exclusiveMs, 60, accuracy: 0.000001)
        XCTAssertEqual(profile.phases.values.reduce(0) { $0 + $1.exclusiveMs }, 150, accuracy: 0.000001)
    }

    func testThrowingAndRepeatedPhasesRemainBalanced() {
        var time = 0.0
        let profile = PhaseProfile(clock: { time })
        XCTAssertThrowsError(try profile.measure("request") {
            try profile.measure("request") { time += 0.02; throw CocoaError(.userCancelled) }
        })
        profile.measure("next") { time += 0.01 }
        XCTAssertEqual(profile.phases["request"]?.calls, 2)
        XCTAssertEqual(profile.phases["request"]!.exclusiveMs, 20, accuracy: 0.000001)
        XCTAssertEqual(profile.phases["next"]!.exclusiveMs, 10, accuracy: 0.000001)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: profile.json))
    }

    func testProfilePreflightsBatchAndRefusesRecursionAndLifecycle() throws {
        XCTAssertEqual(try ProfileRequest(json: #"["ui","full"]"#).command, ["ui", "full"])
        for json in [#"["profile","[]"]"#, #"["stop"]"#, #"["shutdown","all"]"#, #"["tap",42,50]"#,
                     #"["batch","[[\"tap\",\"1\",\"2\"],[\"key\",\"NaN\"]]"]"#] {
            XCTAssertThrowsError(try ProfileRequest(json: json))
        }
        XCTAssertThrowsError(try CommandValidation.validate(["profile"]))
    }
}
