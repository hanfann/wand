// Run with the Settings root already visible on an explicitly selected test watch:
// swift examples/watch/touch-smoke.swift UDID /absolute/path/to/wand /tmp/wand-smoke
// Never boots, resets, or deletes a simulator. Uses only Apple's macOS frameworks.
import AppKit
import Darwin
import Foundation
setbuf(stdout, nil)

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("usage: touch-smoke.swift UDID WAND EVIDENCE_DIR") }
let udid = arguments[1], wand = arguments[2], directory = arguments[3]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

func run(_ executable: String, _ args: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw NSError(domain: "smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    return text
}
var inputTimes: [Double] = []
func command(_ args: String...) throws {
    let start = ProcessInfo.processInfo.systemUptime
    _ = try run(wand, ["--udid", udid] + args)
    if args.first == "tap" { inputTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
}
func capture(_ name: String) throws -> [Double] {
    let path = directory + "/" + name + ".png"
    try command("screenshot", path)
    guard let data = FileManager.default.contents(atPath: path), let bitmap = NSBitmapImageRep(data: data) else { fatalError("missing screenshot") }
    var samples: [Double] = []
    // Ignore the clock and title; compare the actual Settings content.
    for row in 8..<32 { for column in 0..<32 {
        guard let color = bitmap.colorAt(x: column * bitmap.pixelsWide / 32, y: row * bitmap.pixelsHigh / 32)?.usingColorSpace(.deviceRGB) else { fatalError("pixel read failed") }
        samples += [color.redComponent, color.greenComponent, color.blueComponent]
    }}
    return samples
}
func difference(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
}
func require(_ value: Bool, _ message: String) {
    guard value else { print("FAIL: " + message); exit(1) }; print("PASS: " + message)
}
var foreground = ""
let readyDeadline = ProcessInfo.processInfo.systemUptime + 15
repeat {
    foreground = try run(wand, ["--udid", udid, "ui"])
    if foreground.contains("Application \"Settings\"") { break }
    usleep(100_000)
} while ProcessInfo.processInfo.systemUptime < readyDeadline
require(foreground.contains("Application \"Settings\""), "Settings app is foreground before input")
let info = try run(wand, ["--udid", udid, "info"])
let pattern = try NSRegularExpression(pattern: "([0-9]+)x([0-9]+)pt")
let match = pattern.firstMatch(in: info, range: NSRange(info.startIndex..., in: info))!
let width = Double((info as NSString).substring(with: match.range(at: 1)))!
let height = Double((info as NSString).substring(with: match.range(at: 2)))!
let x = String(width * 0.5), y = String(height * 0.4)
let backX = String(width * 0.15), backY = String(height * 0.14)
let skipCrown = ProcessInfo.processInfo.environment["WAND_SMOKE_SKIP_CROWN"] == "1"
if skipCrown {
    print("SKIP: native crown (explicitly excluded; this is not a full-suite pass)")
    try command("scroll", "up", "5")
} else { try command("crown", "up", "10") }
let baseline = try capture("root")
let cycles = Int(ProcessInfo.processInfo.environment["WAND_SMOKE_CYCLES"] ?? "10") ?? 10
for offset in 0..<max(0, cycles) {
    let index = offset + 1
    try command("tap", x, y)
    require(difference(baseline, try capture("tap-\(index)")) > 0.025, "tap \(index) opens Notifications")
    try command("tap", backX, backY)
    require(difference(baseline, try capture("back-\(index)")) < 0.025, "back \(index) returns to Settings")
}
// Find only this simulator's child helper, never another watch's process.
let processes = try run("/bin/ps", ["-axo", "pid=,ppid=,comm=,args="])
let rows = processes.split(separator: "\n").map { $0.split(maxSplits: 3, whereSeparator: { $0.isWhitespace }).map(String.init) }
let boots = rows.filter { $0.count == 4 && $0[2].hasSuffix("launchd_sim") && $0[3].contains(udid) }
if boots.count == 1 {
    let helpers = rows.filter { $0.count == 4 && $0[1] == boots[0][0] && $0[3].hasSuffix("/guest-hid") }
    require(helpers.isEmpty, "HID transport needs no guest helper process")
}
try command("drag", x, String(height * 0.78), x, String(height * 0.3))
require(difference(baseline, try capture("drag")) > 0.025, "vertical drag scrolls")
if skipCrown {
    try command("scroll", "up", "5")
    require(difference(baseline, try capture("scroll-up")) < 0.025, "touch scroll returns to top")
} else {
    try command("crown", "up", "10")
    require(difference(baseline, try capture("crown-up")) < 0.025, "crown returns to top")
    let crownCycles = max(1, Int(ProcessInfo.processInfo.environment["WAND_CROWN_CYCLES"] ?? "1") ?? 1)
    for index in 1...crownCycles {
        try command("crown", "down", "3")
        require(difference(baseline, try capture("crown-down-\(index)")) > 0.025, "native Crown down \(index) scrolls")
        try command("crown", "up", "4")
        require(difference(baseline, try capture("crown-up-\(index)")) < 0.025, "native Crown up \(index) returns to top")
    }
    print("Verified native Crown transitions: \(crownCycles * 2)")
}
require(difference(baseline, try capture("before-batch")) < 0.025, "Settings root verified before batch")
try command("batch", "[[\"tap\",\"\(x)\",\"\(y)\"],[\"tap\",\"\(backX)\",\"\(backY)\"]]")
require(difference(baseline, try capture("batch-return")) < 0.025, "batch navigation returns to Settings")
for (name, json) in [
    ("numeric-preflight", "[[\"tap\",\"\(x)\",\"\(y)\"],[\"key\",\"nan\"]]"),
    ("preflight", "[[\"tap\",\"\(x)\",\"\(y)\"],[\"typo\"]]"),
    ("stop-on-error", "[[\"assert\",\"#MISSING_BATCH_TEST_TARGET\"],[\"tap\",\"\(x)\",\"\(y)\"]]")
] {
    var failed = false
    do { try command("batch", json) } catch { failed = true }
    require(failed, "batch \(name) reports failure")
    require(difference(baseline, try capture("batch-\(name)")) < 0.025, "batch \(name) prevents the tap")
}
print("Watch input smoke test complete; screenshots: \(directory)")

let ordered = inputTimes.sorted()
if !ordered.isEmpty {
    let p95 = ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1]
    let summary: [String: Any] = ["tap_samples": ordered.count,
        "median_ms": ordered[ordered.count / 2], "p95_ms": p95, "max_ms": ordered.last!, "samples_ms": inputTimes]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: directory + "/latency.json"))
    print("Tap latency: n=\(ordered.count), median=\(ordered[ordered.count / 2])ms, p95=\(p95)ms")
    require(p95 < 2000, "observed watch tap p95 below 2 seconds")
}
