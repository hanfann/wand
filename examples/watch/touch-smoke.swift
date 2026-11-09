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
func command(_ args: String...) throws { _ = try run(wand, ["--udid", udid] + args) }
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
    guard value else { fatalError("FAIL: " + message) }; print("PASS: " + message)
}
let info = try run(wand, ["--udid", udid, "info"])
let pattern = try NSRegularExpression(pattern: "([0-9]+)x([0-9]+)pt")
let match = pattern.firstMatch(in: info, range: NSRange(info.startIndex..., in: info))!
let width = Double((info as NSString).substring(with: match.range(at: 1)))!
let height = Double((info as NSString).substring(with: match.range(at: 2)))!
let x = String(width * 0.5), y = String(height * 0.4)
let backX = String(width * 0.15), backY = String(height * 0.14)
try command("crown", "up", "10")
let baseline = try capture("root")
for index in 1...10 {
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
    require(helpers.count == 1, "one HID helper for the selected watch")
    if helpers.count == 1, let pid = Int32(helpers[0][0]) {
        require(kill(pid, SIGTERM) == 0, "stopped only this watch's HID helper")
        usleep(200_000)
        do { try command("tap", x, y) } catch { try command("tap", x, y) }
        require(difference(baseline, try capture("recovered")) > 0.025, "helper recovery delivers the next tap")
        try command("tap", backX, backY)
    }
}
try command("drag", x, String(height * 0.78), x, String(height * 0.3))
require(difference(baseline, try capture("drag")) > 0.025, "vertical drag scrolls")
try command("crown", "up", "10")
require(difference(baseline, try capture("crown-up")) < 0.025, "crown returns to top")
try command("crown", "down", "3")
require(difference(baseline, try capture("crown-down")) > 0.025, "crown scrolls down")
print("Watch input smoke test complete; screenshots: \(directory)")
