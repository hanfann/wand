import XCTest
import Darwin
@testable import WandKit

final class ArtifactMaintenanceTests: XCTestCase {
    func testDryRunAndCleanupPreserveActiveUnknownAndSymlinkFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = UUID().uuidString, inactive = UUID().uuidString
        let activeLog = directory.appendingPathComponent("daemon-\(active).log")
        let inactiveLog = directory.appendingPathComponent("daemon-\(inactive).log")
        let unknown = directory.appendingPathComponent("my-recording.png")
        let external = directory.appendingPathComponent("important.txt")
        for url in [activeLog, inactiveLog, unknown, external] {
            try Data(repeating: 65, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: url.path)
        }
        let symlink = directory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let lockPath = directory.appendingPathComponent("daemon-\(active).sock.owner.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let dry = ArtifactMaintenance.clean(directory: directory, dryRun: true)
        XCTAssertEqual(dry.files, [inactiveLog.lastPathComponent]); XCTAssertEqual(dry.bytes, 100)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        let actual = ArtifactMaintenance.clean(directory: directory, dryRun: false)
        XCTAssertEqual(actual.files, dry.files)
        for url in [activeLog, unknown, external, symlink] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveLog.path))
    }
    func testLogCountAndByteBudgetsEvictOldestInactiveLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<4 {
            let file = directory.appendingPathComponent("daemon-\(UUID().uuidString).log")
            try Data(repeating: 65, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: file.path)
        }
        let report = ArtifactMaintenance.clean(directory: directory, dryRun: false, now: Date(timeIntervalSince1970: 1100), maxLogs: 3, maxLogBytes: 200)
        XCTAssertEqual(report.files.count, 2); XCTAssertEqual(report.bytes, 200)
    }
}
