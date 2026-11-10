import XCTest
@testable import WandKit

final class SnapshotTests: XCTestCase {
    func testDiffKeepsDuplicateControlsAndChangedGeometry() {
        let rows: [[String: Any]] = [
            ["role": "AXButton", "label": "Save", "x": 0.0, "y": 0.0, "w": 40.0, "h": 30.0],
            ["role": "AXButton", "label": "Save", "x": 0.0, "y": 50.0, "w": 40.0, "h": 30.0],
        ]
        let before = Snapshot(elements: rows)
        XCTAssertTrue(Snapshot(elements: [rows[0]]).diff(from: before).contains("- e2"))
        var moved = rows
        moved[1]["y"] = 70.0
        moved[1]["enabled"] = false
        let diff = Snapshot(elements: moved).diff(from: before)
        XCTAssertTrue(diff.contains("~ e2"))
        XCTAssertTrue(diff.contains("@20,85 (disabled)"))
        XCTAssertEqual(before.diff(from: before), "(no change)")
    }

    func testEmptyAndMissingRefsNeverFallBackToLabels() {
        let snapshot = sample()
        XCTAssertNil(snapshot.resolve(""))
        XCTAssertNil(snapshot.resolve("#"))
        XCTAssertNil(snapshot.resolve("e999"))
    }

    func testInvalidGeometryDoesNotCrashFormatting() {
        let snapshot = Snapshot(elements: [
            ["role": "AXButton", "x": Double.nan, "y": 0.0, "w": 10.0, "h": 10.0],
            ["role": "AXButton", "x": 0.0, "y": Double.infinity, "w": 10.0, "h": 10.0],
        ])
        XCTAssertEqual(snapshot.compact, "")
    }
    // A representative tree: a button with id, a label-only text, a value field,
    // a decorative empty container (should be filtered), and an off-screen row.
    func sample(screenW: Double = 400, screenH: Double = 800) -> Snapshot {
        let elements: [[String: Any]] = [
            ["role": "AXApplication", "label": "App", "x": 0.0, "y": 0.0, "w": 400.0, "h": 800.0, "depth": 0],
            ["role": "AXButton", "label": "Tap me", "id": "tapButton", "x": 50.0, "y": 100.0, "w": 120.0, "h": 40.0, "depth": 1, "enabled": true],
            ["role": "AXStaticText", "label": "Hello", "x": 50.0, "y": 160.0, "w": 100.0, "h": 20.0, "depth": 1],
            ["role": "AXTextField", "id": "email", "value": "a@b.co", "x": 50.0, "y": 200.0, "w": 200.0, "h": 30.0, "depth": 1],
            ["role": "AXGroup", "x": 0.0, "y": 0.0, "w": 400.0, "h": 50.0, "depth": 1], // no label/id -> filtered
            ["role": "AXButton", "label": "Disabled", "id": "off", "x": 50.0, "y": 240.0, "w": 80.0, "h": 30.0, "depth": 1, "enabled": false],
            ["role": "AXCell", "label": "Row 99", "id": "row-99", "x": 50.0, "y": 1500.0, "w": 300.0, "h": 40.0, "depth": 1], // off-screen
        ]
        return Snapshot(elements: elements, screenW: screenW, screenH: screenH)
    }

    func testInterestingFilterDropsEmptyContainers() {
        let snap = sample()
        XCTAssertFalse(snap.all.contains { $0.role == "AXGroup" }, "empty AXGroup should be filtered out")
        // App + button + text + field + disabled button + off-screen row = 6
        XCTAssertEqual(snap.all.count, 6)
    }

    func testRefsAreStableAndAddressable() {
        let snap = sample()
        XCTAssertNotNil(snap.byRef["e1"])
        XCTAssertEqual(snap.resolve("e2")?.label, "Tap me")
    }

    func testViewportFiltering() {
        let snap = sample()
        XCTAssertTrue(snap.visible.allSatisfy { $0.onScreen })
        XCTAssertFalse(snap.visible.contains { $0.id == "row-99" }, "off-screen row excluded from visible")
        XCTAssertTrue(snap.all.contains { $0.id == "row-99" }, "but present in full tree")
    }

    func testResolveById() {
        let snap = sample()
        XCTAssertEqual(snap.resolve("#tapButton")?.label, "Tap me")
        XCTAssertEqual(snap.resolve("#email")?.value, "a@b.co")
    }

    func testResolveByLabelCaseInsensitive() {
        let snap = sample()
        XCTAssertEqual(snap.resolve("tap me")?.id, "tapButton")
        XCTAssertEqual(snap.resolve("HELLO")?.role, "AXStaticText")
    }

    func testCenterCoordinates() {
        let snap = sample()
        let b = snap.resolve("#tapButton")!
        XCTAssertEqual(b.cx, 110)  // 50 + 120/2
        XCTAssertEqual(b.cy, 120)  // 100 + 40/2
    }

    func testCompactLineFormat() {
        let snap = sample()
        let line = snap.line(snap.resolve("#tapButton")!)
        XCTAssertTrue(line.contains("Button"))
        XCTAssertTrue(line.contains("\"Tap me\""))
        XCTAssertTrue(line.contains("#tapButton"))
        XCTAssertTrue(line.contains("@110,120"))
    }

    func testDisabledFlag() {
        let snap = sample()
        let line = snap.line(snap.resolve("#off")!)
        XCTAssertTrue(line.contains("(disabled)"))
    }

    func testFind() {
        let snap = sample()
        XCTAssertEqual(snap.find("row").count, 1)
        XCTAssertTrue(snap.find("button").count >= 2) // role match
    }

    func testDiffDetectsValueChange() {
        let before = sample()
        let after = Snapshot(elements: [
            ["role": "AXTextField", "id": "email", "value": "changed@x.co", "x": 50.0, "y": 200.0, "w": 200.0, "h": 30.0],
        ], screenW: 400, screenH: 800)
        let d = after.diff(from: before)
        XCTAssertTrue(d.contains("~"), "value change should show as modified")
        XCTAssertTrue(d.contains("changed@x.co"))
    }

    func testResolvePrefersOnScreen() {
        // Two elements with the same label; the on-screen one should win.
        let snap = Snapshot(elements: [
            ["role": "AXButton", "label": "Save", "x": 10.0, "y": 1200.0, "w": 80.0, "h": 30.0], // off-screen
            ["role": "AXButton", "label": "Save", "x": 10.0, "y": 300.0, "w": 80.0, "h": 30.0],  // on-screen
        ], screenW: 400, screenH: 800)
        XCTAssertEqual(snap.resolve("Save")?.cy, 315)
    }
}
