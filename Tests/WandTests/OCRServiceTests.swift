import Foundation
import XCTest
import Darwin
@testable import wand

final class OCRServiceTests: XCTestCase {
    private var directory: URL!
    private var service: OCRService!
    private var time: TimeInterval = 100

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-ocr-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("worker")
        let root = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try """
        #!/bin/sh
        cd \(root) || exit 1
        printf '%s|%s|%s|%s|%s\\n' "$5" "$2" "$3" "$4" "$$" >> calls
        if [ "$5" = accurate ] && [ -f stall ]; then exec /bin/sleep 30; fi
        if [ -f invalid ]; then printf 'invalid'; exit 0; fi
        if [ -f empty ]; then printf '[]'; exit 0; fi
        printf '[{"text":"%s","x":10,"y":20,"w":40,"h":10,"conf":0.95}]' "$5"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        service = OCRService(workerExecutable: executable.path, temporaryDirectory: directory.path, now: { [unowned self] in self.time })
    }

    override func tearDownWithError() throws {
        let scratch = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ocr-") }
        XCTAssertEqual(scratch, [], "capture and result files must be removed on every exit")
        try FileManager.default.removeItem(at: directory)
        service = nil
    }

    private func marker(_ name: String, present: Bool = true) throws {
        let url = directory.appendingPathComponent(name)
        if present { try Data().write(to: url) }
        else { try FileManager.default.removeItem(at: url) }
    }

    private var calls: [[String]] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.split(separator: "|").map(String.init) }
    }

    private func frame<T>(_ pixels: String = "frame-A", width: Double = 100,
                          body: (OCRService.Frame) throws -> T) throws -> T {
        try service.withFrame(width: width, height: 100, capture: { path in
            try Data(pixels.utf8).write(to: URL(fileURLWithPath: path))
        }, body: body)
    }

    private func recognize(_ pixels: String = "frame-A", accurate: Bool = false, automatic: Bool = false) throws -> [[String: Any]] {
        try frame(pixels) { try service.recognize(frame: $0, accurate: accurate, automatic: automatic) }
    }

    private func assertFailure(_ expected: OCRService.Failure, _ body: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? OCRService.Failure, expected, file: file, line: line)
        }
    }

    func testFallbackSharesOneCaptureAndModesRemainCached() throws {
        var captures = 0
        try service.withFrame(width: 100, height: 100, capture: { path in
            captures += 1
            try Data("frame-A".utf8).write(to: URL(fileURLWithPath: path))
        }) { image in
            XCTAssertEqual(try service.recognize(frame: image).first?["text"] as? String, "fast")
            XCTAssertEqual(try service.recognize(frame: image, accurate: true, automatic: true).first?["text"] as? String, "accurate")
        }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0][1], calls[1][1], "both workers must read the same captured file")
        XCTAssertEqual(try recognize().first?["text"] as? String, "fast")
        XCTAssertEqual(try recognize(accurate: true).first?["text"] as? String, "accurate")
        XCTAssertEqual(calls.count, 2, "alternating modes must not evict each other")
    }

    func testPixelAndGeometryChangesInvalidateBothModesAndBoundCache() throws {
        _ = try recognize()
        _ = try recognize(accurate: true)
        _ = try recognize("frame-B")
        _ = try recognize("frame-B", accurate: true)
        _ = try frame("frame-B", width: 200) { try service.recognize(frame: $0) }
        _ = try recognize() // Returning to A cannot resurrect a retained older frame.
        XCTAssertEqual(calls.map { $0[0] }, ["fast", "accurate", "fast", "accurate", "fast", "fast"])
        XCTAssertEqual(calls[4][2], "200.0")
    }

    func testTimeoutSuppressesAutomaticRetriesUntilExpiryAndKeepsFastCache() throws {
        _ = try recognize()
        try marker("stall")
        let start = ProcessInfo.processInfo.systemUptime
        assertFailure(.timedOut) { _ = try recognize(accurate: true, automatic: true) }
        let timeoutElapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(timeoutElapsed, 5)
        XCTAssertLessThan(timeoutElapsed, 5.5)
        let timedOutPID = try XCTUnwrap(Int32(calls.last![4]))
        let retryStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            assertFailure(.coolingDown) { _ = try recognize(accurate: true, automatic: true) }
        }
        let retriesElapsed = ProcessInfo.processInfo.systemUptime - retryStart
        XCTAssertLessThan(retriesElapsed, 1, "twenty refused retries must not pay worker deadlines")
        _ = try recognize()
        XCTAssertEqual(calls.count, 2, "timeout must preserve the fast result; cooldown starts no worker")
        XCTAssertEqual(kill(timedOutPID, 0), -1, "timed-out worker must be stopped")
        XCTAssertEqual(errno, ESRCH)
        print("OCR timeout \(timeoutElapsed)s; 20 suppressed retries \(retriesElapsed)s; workers started \(calls.count)")
        try marker("stall", present: false)
        time += 59
        assertFailure(.coolingDown) { _ = try recognize("new-frame", accurate: true, automatic: true) }
        time += 1
        XCTAssertEqual(try recognize("new-frame", accurate: true, automatic: true).first?["text"] as? String, "accurate")
        XCTAssertEqual(calls.count, 3)
    }

    func testExplicitRetryBypassesCooldownAndSuccessRestoresAutomaticFallback() throws {
        try marker("stall")
        assertFailure(.timedOut) { _ = try recognize(accurate: true) }
        try marker("stall", present: false)
        try marker("invalid")
        assertFailure(.workerFailed) { _ = try recognize(accurate: true) }
        assertFailure(.coolingDown) { _ = try recognize(accurate: true, automatic: true) }
        try marker("invalid", present: false)
        _ = try recognize(accurate: true)
        _ = try recognize("frame-B", accurate: true, automatic: true)
        XCTAssertEqual(calls.count, 4)
    }

    func testCancellationStopsWorkerWithoutStartingCooldown() throws {
        try marker("stall")
        service.cancelled = { [unowned self] in !self.calls.isEmpty }
        let start = ProcessInfo.processInfo.systemUptime
        assertFailure(.cancelled) { _ = try recognize(accurate: true, automatic: true) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        service.cancelled = nil
        try marker("stall", present: false)
        _ = try recognize(accurate: true, automatic: true)
        XCTAssertEqual(calls.count, 2)
        service.cancelled = { true }
        assertFailure(.cancelled) { _ = try recognize(accurate: true) }
        XCTAssertEqual(calls.count, 2, "cancelled requests must not return cached targets or launch workers")
    }

    func testCaptureFailureAndInvalidWorkerOutputAreNotCached() throws {
        XCTAssertThrowsError(try service.withFrame(width: 100, height: 100, capture: { path in
            try Data("partial".utf8).write(to: URL(fileURLWithPath: path))
            throw CocoaError(.fileReadUnknown)
        }, body: { _ in XCTFail("failed capture must not reach recognition") }))
        XCTAssertTrue(calls.isEmpty)
        try marker("invalid")
        assertFailure(.workerFailed) { _ = try recognize(accurate: true, automatic: true) }
        try marker("invalid", present: false)
        _ = try recognize(accurate: true, automatic: true)
        XCTAssertEqual(calls.count, 2)
    }

    func testEmptySuccessfulResultsAreCachedPerMode() throws {
        try marker("empty")
        XCTAssertTrue(try recognize().isEmpty)
        XCTAssertTrue(try recognize(accurate: true).isEmpty)
        XCTAssertTrue(try recognize().isEmpty)
        XCTAssertTrue(try recognize(accurate: true).isEmpty)
        XCTAssertEqual(calls.count, 2)
    }
}
