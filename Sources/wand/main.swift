import Foundation
import Darwin
import WandEngine

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
wand — autonomous Apple-simulator (iOS · iPadOS · watchOS) E2E driver for AI agents

  Observe:
    wand ui [diff|full]            on-screen snapshot (diff=changes, full=incl. off-screen)
    wand see                       OCR every visible text + tap coords (any app)
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

  App / device:
    wand devices                   booted simulators
    wand boot <udid|name> | shutdown <udid|all>
    wand install <app> | launch <bundle> | terminate <bundle> | apps
    wand logs [bundle] [seconds]   recent app console logs
    wand crashes [bundle]          newest crash report, if any
    wand open <url>                open a deep link / universal link
    wand permission <grant|revoke|reset> <service> <bundle>
    wand record <start [path]|stop>

  Target a specific sim with --udid <udid> (default: the booted one).
  Setup / daemon: wand setup | start | stop | status | info | mcp
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

// One-shot post-install: install the Claude Code skill + register the MCP server.
// Works for both Homebrew (skill under <prefix>/share) and source installs.
func runSetup() {
    let home = NSHomeDirectory()
    let skillDir = home + "/.claude/skills/wand"
    let exe = Client.executablePath()
    let exeDir = (exe as NSString).deletingLastPathComponent
    let candidates = [
        exeDir + "/../share/wand/skills/wand/SKILL.md",
        exeDir + "/../share/wand/SKILL.md",
        exeDir + "/../skills/wand/SKILL.md",
        FileManager.default.currentDirectoryPath + "/skills/wand/SKILL.md",
    ].map { ($0 as NSString).standardizingPath }

    if let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        try? FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        let dst = skillDir + "/SKILL.md"
        try? FileManager.default.removeItem(atPath: dst)
        do { try FileManager.default.copyItem(atPath: src, toPath: dst); out("✓ skill installed → \(dst)") }
        catch { err("• could not copy skill: \(error.localizedDescription)") }
    } else {
        out("• skill file not found near binary (MCP still works)")
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["claude", "mcp", "add", "wand", "--", exe, "mcp"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    if (try? p.run()) != nil {
        p.waitUntilExit()
        if p.terminationStatus == 0 { out("✓ MCP server registered with Claude Code") }
        else { out("• register MCP manually:  claude mcp add wand -- \(exe) mcp") }
    } else {
        out("• Claude Code CLI not found. Register MCP with:\n    claude mcp add wand -- \(exe) mcp")
    }
    out("\nDone. Boot a simulator, then:  wand info && wand ui")
}

func requireUDID(_ explicit: String?) -> String {
    guard let u = Simctl.resolveUDID(explicit) else {
        err("no booted simulator. Boot one (wand boot <name>) or pass --udid.")
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
case "__daemon":
    _ = setsid()
    do {
        let udid = Simctl.resolveUDID(nil)
        let sim = try (udid.map { try WNDSimulator.withUDID($0) } ?? WNDSimulator.bootedSimulator())
        Daemon(sim: sim).serve()
    } catch {
        err("wandd: \(error.localizedDescription)")
        exit(1)
    }

case "mcp":
    MCP.run()

case "setup":
    runSetup()

case "help", "-h", "--help":
    out(usage)

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
    let (code, o) = Simctl.run(["boot", udid])
    Simctl.run(["bootstatus", udid, "-b"])
    _ = Simctl.run(["io", udid, "screenshot", "/dev/null"]) // nudge
    Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "Simulator"])
    out(code == 0 || o.contains("current state: Booted") ? "booted \(udid)" : o)

case "shutdown" where argv.count >= 2:
    let (code, o) = Simctl.run(["shutdown", argv[1]])
    out(code == 0 ? "shutdown \(argv[1])" : o)

case "start":
    let udid = requireUDID(explicitUDID)
    if Client.daemonRunning(udid) { out("already running for \(udid)"); break }
    Client.spawnDaemon(udid)
    var ready = false
    for _ in 0..<200 { usleep(100 * 1000); if Client.daemonRunning(udid) { ready = true; break } }
    let (ok, text) = ready ? Client.send(udid, ["info"]) : (false, "failed to start")
    out(ok ? "started: \(text)" : text)

case "stop":
    let udid = requireUDID(explicitUDID)
    if Client.daemonRunning(udid) { _ = Client.sendOnce(udid, ["stop"]); out("stopped \(udid)") }
    else { out("not running") }

case "status":
    let udid = requireUDID(explicitUDID)
    let (ok, text) = Client.daemonRunning(udid) ? Client.send(udid, ["ping"]) : (false, "not running")
    out(ok ? "running: \(text)" : text); exit(ok ? 0 : 1)

default:
    route(requireUDID(explicitUDID), argv)
}
