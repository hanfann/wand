import Foundation
import Darwin
import WandEngine
import WandKit

signal(SIGPIPE, SIG_IGN)

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
wand — autonomous Apple-simulator (iOS · iPadOS · watchOS) E2E driver for AI agents

  Observe:
    wand ui [diff|full]            on-screen snapshot (diff=changes, full=incl. off-screen)
    wand see [accurate] [query]    bounded OCR; optional text filter (points)
    wand find <query>              elements matching label/id/value/role
    wand scrollto <sel>            scroll until an element is visible
    wand assert <sel> [exists|gone|value=..|label=..]
    wand wait <sel> [timeoutMs]
    wand screenshot [path]

  Act (sel = eN | #id | "label"; tap falls back to OCR text):
    wand tap <sel> | wand tap <x> <y> | wand tapocr <text>
    wand typein <sel> <text> | wand type <text> | wand setvalue <sel> <text>
    wand clear <sel> | wand key <hidUsage>
    wand swipe|drag|dragdrop <x1> <y1> <x2> <y2>   (drag/dragdrop also <fromSel> <toSel>)
    wand longpress <sel|x y> | pinch <sel|x y> <scale> | rotate <sel|x y> <radians>
    wand scroll up|down [clicks]   swipe-based scroll (iOS · iPadOS · watchOS)
    wand crown up|down [clicks]    watchOS Digital Crown, N detents (down = toward end)
    wand crown <delta> [steps]     raw crown turn (sign = direction)

  Sequences:
    wand batch '[["tap","40","80"],["ui","diff"]]'
    wand batch -                   read the same JSON from stdin; stop at first failure

  App / device:
    wand devices                   booted simulators
    wand boot <udid|name> [--show] | shutdown <udid|all>
    wand install <app> | launch <bundle> | terminate <bundle> | apps
    wand logs [bundle] [seconds]   recent app console logs
    wand crashes [bundle]          newest crash report, if any
    wand open <url>                open a deep link / universal link
    wand permission <grant|revoke|reset> <service> <bundle>
    wand record <start [path]|stop>

  Target a specific sim with --udid <udid> (default: the booted one).
  Setup: wand setup [--mcp] [--full-mcp] | mcp [--compact]
  Maintenance: cleanup [--dry-run]    prune inactive logs/OCR scratch only
  Daemon: start | stop | status | info
"""

// --- parse a global --udid flag ---
var explicitUDID: String? = nil
var rawArgs = Array(CommandLine.arguments.dropFirst())
if let i = rawArgs.firstIndex(of: "--udid"), i + 1 < rawArgs.count {
    explicitUDID = rawArgs[i + 1]
    rawArgs.removeSubrange(i...(i + 1))
}
let argv = rawArgs
let cmd = argv.first ?? "help"

// One shared skill for Claude and Codex. MCP is opt-in because the CLI plus
// skill avoids loading a tool catalog; compact MCP exposes one batch tool.
func runSetup() {
    let home = NSHomeDirectory()
    let exe = Client.executablePath()
    let exeDir = (exe as NSString).deletingLastPathComponent
    let candidates = [
        exeDir + "/../share/wand/skills/wand/SKILL.md",
        exeDir + "/../share/wand/SKILL.md",
        exeDir + "/../skills/wand/SKILL.md",
        FileManager.default.currentDirectoryPath + "/skills/wand/SKILL.md",
    ].map { ($0 as NSString).standardizingPath }
    let fm = FileManager.default
    guard let src = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
        err("skill file not found near binary; run setup from the Wand source checkout or reinstall")
        exit(1)
    }
    do {
        let shared = home + "/.agents/skills/wand"
        let claude = home + "/.claude/skills/wand"
        try fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: claude, withIntermediateDirectories: true)
        let canonical = shared + "/SKILL.md", link = claude + "/SKILL.md"
        try Data(contentsOf: URL(fileURLWithPath: src)).write(to: URL(fileURLWithPath: canonical), options: .atomic)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != canonical {
            if fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                try fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: canonical)
        }
        out("skill updated for Claude and Codex → \(canonical)")
    } catch {
        err("could not install skill: \(error.localizedDescription)")
        exit(1)
    }
    guard argv.contains("--mcp") || argv.contains("--full-mcp") else {
        out("CLI ready. Optional MCP: wand setup --mcp (one compact tool)")
        return
    }
    let args = ["claude", "mcp", "add", "wand", "--", exe, "mcp"]
        + (argv.contains("--full-mcp") ? [] : ["--compact"])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do {
        try p.run()
        let response = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { out("MCP server registered with Claude Code") }
        else {
            err(String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            err("Inspect an existing registration with: claude mcp get wand")
            exit(1)
        }
    } catch { err("Claude CLI unavailable. Register manually: " + args.joined(separator: " ")); exit(1) }
}

func requireUDID(_ explicit: String?) -> String {
    guard let u = Simctl.resolveUDID(explicit) else {
        err("no unique target simulator. Pass --udid or WAND_UDID; otherwise exactly one must be booted.")
        exit(1)
    }
    return u
}

func route(_ udid: String, _ argv: [String]) -> Never {
    let (ok, text) = Client.send(udid, argv)
    if ok { out(text) } else { err(text); exit(1) }
    exit(0)
}

switch cmd {
case "__ax":
    guard argv.count == 2 else { exit(1) }
    AccessibilityService.run(udid: argv[1])

case "__ocr":
    OCRService.worker(Array(argv.dropFirst()))

case "__daemon":
    _ = setsid()
    let startupMonitor = WorkerLifetime.monitorParent()
    do {
        let udid = requireUDID(nil)
        let ownership = Daemon.acquireOwnership(udid: udid)
        if ProcessInfo.processInfo.environment["WAND_TEST_DAEMON_STARTUP_STALL"] == "1" {
            while true { pause() }
        }
        let sim = try WNDSimulator.withUDID(udid)
        Daemon(sim: sim, ownerLock: ownership).serve(startupMonitor: startupMonitor)
    } catch {
        err("wandd: \(error.localizedDescription)")
        exit(1)
    }

case "mcp":
    MCP.run(compact: argv.contains("--compact"), defaultUDID: explicitUDID)

case "setup":
    runSetup()

case "batch":
    guard argv.count == 2 else { err("batch needs JSON or - for stdin"); exit(1) }
    let json = argv[1] == "-"
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : argv[1]
    route(requireUDID(explicitUDID), ["batch", json])

case "help", "-h", "--help":
    out(usage)

case "cleanup":
    guard argv.dropFirst().allSatisfy({ $0 == "--dry-run" }) else { err("cleanup accepts only --dry-run"); exit(1) }
    let dry = argv.contains("--dry-run")
    let report = Maintenance.run(dryRun: dry)
    out("\(dry ? "Would remove" : "Removed") \(report.files.count) inactive artifacts (\(report.bytes) bytes)")
    if !report.files.isEmpty { out(report.files.joined(separator: "\n")) }

case "layout":
    out(WNDSimulator.layoutDescription())

case "devices":
    let booted = Simctl.bootedDevices()
    if booted.isEmpty { out("no booted simulators") }
    else { out(booted.map { "\($0.udid)  \($0.name)  (\($0.state))" }.joined(separator: "\n")) }

case "boot" where argv.count >= 2:
    let arg = argv[1]
    let dev = Simctl.allDevices().first { $0.udid == arg || $0.name == arg }
    let udid = dev?.udid ?? arg
    let (code, response) = Simctl.run(["boot", udid])
    guard code == 0 || response.contains("current state: Booted") else { err(response); exit(1) }
    let (ready, detail) = Simctl.run(["bootstatus", udid, "-b"])
    guard ready == 0 else { err(detail); exit(1) }
    if argv.contains("--show") {
        let selected = ProcessRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        guard selected.status == 0 else { err(selected.output); exit(1) }
        let developer = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let applications = (developer as NSString).deletingLastPathComponent + "/Applications/"
        let app = ["DeviceHub.app", "Simulator.app"].map { applications + $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let app else { err("simulator booted; no DeviceHub/Simulator app in selected Xcode"); exit(1) }
        let viewer = ProcessRunner.run("/usr/bin/open", ["-a", app], timeout: 10)
        guard viewer.status == 0 else { err("simulator booted; could not open viewer: " + viewer.output); exit(1) }
    }
    out("booted \(udid)")

case "shutdown" where argv.count >= 2:
    let targets = argv[1] == "all" ? Simctl.bootedDevices().map(\.udid) : [argv[1]]
    for target in targets where Client.daemonRunning(target) { _ = Client.sendOnce(target, ["stop"], timeout: 6) }
    let (code, response) = Simctl.run(["shutdown", argv[1]])
    if code == 0 { out("shutdown \(argv[1])") }
    else { err(response); exit(1) }

case "start":
    let udid = requireUDID(explicitUDID)
    let (ok, text) = Client.send(udid, ["info"])
    if ok { out("started: \(text)") }
    else { err(text); exit(1) }

case "stop":
    let udid = requireUDID(explicitUDID)
    if Client.daemonRunning(udid) {
        guard let reply = Client.sendOnce(udid, ["stop"], timeout: 6), reply.0 else {
            err("daemon did not acknowledge stop within 6 seconds; no process was killed"); exit(1)
        }
        for _ in 0..<500 {
            if !Client.daemonRunning(udid) { break }
            usleep(10_000)
        }
        if Client.daemonRunning(udid) { err("daemon did not stop"); exit(1) }
        out("stopped \(udid)")
    } else { out("not running") }

case "status":
    let udid = requireUDID(explicitUDID)
    let (ok, text) = Client.daemonRunning(udid) ? Client.send(udid, ["ping"]) : (false, "not running")
    out(ok ? "running: \(text)" : text); exit(ok ? 0 : 1)

default:
    route(requireUDID(explicitUDID), argv)
}
