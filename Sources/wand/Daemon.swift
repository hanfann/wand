import Foundation
import Darwin
import WandEngine
import WandKit

// The warm daemon. Holds a connected WNDSimulator and the last snapshot (for
// ref resolution + diffing). One command per connection; commands are serialized
// against the single simulator, so no locking is needed.
final class Daemon {
    private let ownerLock: Int32
    let sim: WNDSimulator
    var last: Snapshot?
    var recorder: Process?
    var recorderPath: String?
    var lastBundle: String?
    // The device's launchd_sim PID(s) at connect time. If they all die, the
    // simulator was rebooted/erased and our HID + device handles are stale —
    // only a fresh daemon process can rebind, so we exit and let the client
    // respawn. (sim.isBooted() can't see this: it still reports Booted.)
    let bootPids: [Int32]
    // Non-nil if the host Simulator build is unsupported (Indigo wire-format
    // mismatch) or the device can't inject (missing HID client/symbols). When
    // set, the daemon refuses input with this message instead of sending wrong
    // bytes — fail loud, never silent-wrong.
    let startupError: String?
    var guestHID: GuestHIDTransport?

    // Commands that inject HID events; their replies are checked for send errors.
    static let inputCommands: Set<String> = [
        "tap", "tapocr", "type", "typein", "setvalue", "clear", "key",
        "swipe", "drag", "dragdrop", "longpress", "pinch", "rotate", "crown", "scroll",
    ]

    static func commandOf(_ line: String) -> String? {
        guard let d = line.data(using: .utf8),
              let argv = (try? JSONSerialization.jsonObject(with: d)) as? [String] else { return nil }
        return argv.first
    }

    init(sim: WNDSimulator) {
        let lock = open(Net.socketPath(sim.udid) + ".owner.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        self.ownerLock = lock
        signal(SIGPIPE, SIG_IGN)
        self.sim = sim
        self.bootPids = Client.deviceBootPids(sim.udid)
        var error = WNDSimulator.wireFormatError()
        if error == nil, sim.isWatch {
            do {
                if try GuestHIDTransport.isNeeded(udid: sim.udid) {
                    let transport = try GuestHIDTransport(udid: sim.udid)
                    self.guestHID = transport
                    sim.setGuestTouchSender { transport.send($0) }
                }
            } catch let failure { error = failure.localizedDescription }
        }
        self.startupError = error ?? sim.readinessError()
    }

    // Stale if the device shut down, or if every launchd_sim we bound to is gone
    // (a reboot replaces it). Empty bootPids = couldn't determine → don't guess.
    func isSessionStale() -> Bool {
        if !sim.isBooted() { return true }
        if bootPids.isEmpty { return false }
        return !bootPids.contains { kill($0, 0) == 0 }
    }

    struct Reply { var ok: Bool; var text: String }

    func serve() {
        let path = Net.socketPath(sim.udid)
        let fd = Net.listen(path)
        guard fd >= 0 else {
            FileHandle.standardError.write("wandd: cannot bind \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        // Warm the AXPTranslator so the first client call is fast (~66ms not ~3.5s).
        last = try? snapshot()
        FileHandle.standardError.write("wandd: ready on \(path) [\(sim.name)]\n".data(using: .utf8)!)

        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            if let line = Net.readLine(c) {
                var reply = handle(line)
                // P0: if an input command reported success but the HID send failed,
                // surface that instead of a misleading "ok" (no silent failures).
                if reply.ok, let cmd = Daemon.commandOf(line),
                   Daemon.inputCommands.contains(cmd), let se = sim.lastSendError() {
                    reply = Reply(ok: false, text: "input may not have landed (HID send error): \(se)")
                }
                let obj: [String: Any] = ["ok": reply.ok, "text": reply.text]
                if let data = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: data, encoding: .utf8) {
                    Net.writeLine(c, s)
                }
            }
            close(c)
        }
    }

    // --- snapshot helpers ---

    func snapshot() throws -> Snapshot {
        let tree = try sim.accessibilityTree()
        let snap = Snapshot(elements: tree,
                            screenW: Double(sim.screenPointSize.width),
                            screenH: Double(sim.screenPointSize.height))
        last = snap
        return snap
    }

    func currentForResolve() -> Snapshot {
        if let l = last { return l }
        return (try? snapshot()) ?? Snapshot(elements: [])
    }

    // Poll the tree until two consecutive reads are identical (UI quiescent) or
    // the timeout elapses — waits out animations/navigation without guessing.
    func settle(maxMs: Int = 1500) {
        var previous = ""
        var stableReads = 0
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(maxMs) {
            guard let tree = try? sim.accessibilityTree() else { break }
            let sparse = tree.count <= 1
            var signature = "\(tree.count)|" + tree.prefix(80).compactMap {
                ($0["label"] as? String) ?? ($0["value"] as? String) ?? ($0["role"] as? String)
            }.joined(separator: "·")
            if sparse { signature += "|pixels:\(sim.screenFingerprint())" }
            stableReads = signature == previous ? stableReads + 1 : 0
            if stableReads >= (sparse ? 3 : 1),
               Date().timeIntervalSince(start) >= (sparse ? 0.65 : 0.09) { return }
            previous = signature
            usleep(90 * 1000)
        }
    }

    // The app's executable (process) name, from its installed Info.plist.
    func appExecutable(_ bundle: String) -> String? {
        let (c, path) = Simctl.run(["get_app_container", sim.udid, bundle, "app"])
        guard c == 0 else { return nil }
        let plist = path.trimmingCharacters(in: .whitespacesAndNewlines) + "/Info.plist"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        p.arguments = ["-c", "Print CFBundleExecutable", plist]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let exe = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (exe?.isEmpty == false) ? exe : nil
    }

    // Newest crash report (.ips) for the sim, optionally filtered by process name.
    func latestCrash(matching exe: String?) -> (String?, String) {
        let home = NSHomeDirectory()
        let dirs = [
            "\(home)/Library/Developer/CoreSimulator/Devices/\(sim.udid)/data/Library/Logs/DiagnosticReports",
            "\(home)/Library/Logs/DiagnosticReports",
        ]
        let fm = FileManager.default
        var candidates: [(String, Date)] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".ips") || n.hasSuffix(".crash") {
                if let exe = exe, !n.hasPrefix(exe) { continue }
                let full = dir + "/" + n
                let m = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? nil
                candidates.append((full, m ?? .distantPast))
            }
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 })?.0 else { return (nil, "") }
        let content = (try? String(contentsOfFile: newest, encoding: .utf8)) ?? ""
        let head = content.split(separator: "\n").prefix(60).joined(separator: "\n")
        return (newest, head)
    }

    // Installed user apps via `simctl listapps` (old-style plist) -> plutil JSON.
    func userApps() -> [String] {
        let (_, o) = Simctl.run(["listapps", sim.udid])
        let tmp = "\(Net.socketDir())/apps.plist"
        try? o.write(toFile: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-convert", "json", "-o", "-", "--", tmp]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        return obj.compactMap { (bid, v) -> String? in
            guard let dict = v as? [String: Any], (dict["ApplicationType"] as? String) == "User" else { return nil }
            return bid
        }.sorted()
    }

    // Resolve a selector to its element center (for gesture targeting by id/label).
    func center(_ sel: String) -> (Double, Double)? {
        guard let el = currentForResolve().resolve(sel) else { return nil }
        return (Double(el.cx), Double(el.cy))
    }

    // OCR fallback: find visible text on screen (works with no app accessibility).
    func ocrCenter(matching query: String) -> (Double, Double, String)? {
        let q = query.lowercased()
        guard let obs = try? sim.recognizeText() else { return nil }
        let hit = obs.first { (($0["text"] as? String)?.lowercased() == q) }
            ?? obs.first { (($0["text"] as? String)?.lowercased().contains(q) ?? false) }
        guard let h = hit,
              let x = h["x"] as? Double, let y = h["y"] as? Double,
              let w = h["w"] as? Double, let ht = h["h"] as? Double,
              let text = h["text"] as? String else { return nil }
        return (x + w / 2, y + ht / 2, text)
    }

    static func clean(_ sel: String) -> String {
        var s = sel
        if s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // --- command dispatch ---

    func handle(_ line: String) -> Reply {
        guard let data = line.data(using: .utf8),
              let argv = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              let cmd = argv.first else {
            return Reply(ok: false, text: "bad request")
        }
        let a = Array(argv.dropFirst())
        func num(_ i: Int) -> Double { i < a.count ? (Double(a[i]) ?? 0) : 0 }

        // P0: under an unsupported Simulator build (or a device that can't inject)
        // refuse loudly rather than send wrong bytes. ping/stop stay usable.
        if let e = startupError, cmd != "ping", cmd != "stop" {
            return Reply(ok: false, text: "wand: \(e)")
        }
        sim.clearLastSendError()

        do {
            // Resilience: if the bound simulator was shut down or rebooted, exit
            // cleanly and signal the client (via the sentinel) to respawn a fresh
            // daemon and retry — transparently self-healing across sim reboots.
            if cmd != "ping", cmd != "info", cmd != "stop", isSessionStale() {
                Reply.respondThenExit()
                return Reply(ok: false, text: Client.staleSentinel)
            }
            switch cmd {
            case "ping":
                return Reply(ok: true, text: "pong \(sim.name)")

            case "info":
                return Reply(ok: true, text: "\(sim.name) [\(sim.udid)] \(Int(sim.screenPointSize.width))x\(Int(sim.screenPointSize.height))pt @\(sim.screenScale)x")

            case "ui":
                let prev = last
                let snap = try snapshot()
                if a.contains("diff"), let prev = prev {
                    return Reply(ok: true, text: snap.diff(from: prev))
                }
                let full = a.contains("full")
                let els = full ? snap.all : snap.visible
                let header = "\(els.count) elements" + (full ? " (full tree)" : " (on screen)")
                let body = els.map(snap.line).joined(separator: "\n")
                return Reply(ok: true, text: header + "\n" + body)

            case "scrollto", "scrollTo":
                guard !a.isEmpty else { return Reply(ok: false, text: "scrollTo needs a selector") }
                let sel = a.joined(separator: " ")
                let w = Double(sim.screenPointSize.width)
                let h = Double(sim.screenPointSize.height)
                for _ in 0..<14 {
                    let snap = try snapshot()
                    if let el = snap.resolve(sel), el.onScreen {
                        return Reply(ok: true, text: "visible \(snap.line(el))")
                    }
                    // Decide direction: known-above -> scroll up, else scroll down.
                    let above = snap.resolve(sel).map { $0.y < 0 } ?? false
                    if above {
                        try sim.swipe(x1: w / 2, y1: h * 0.28, x2: w / 2, y2: h * 0.72, duration: 0.25)
                    } else {
                        try sim.swipe(x1: w / 2, y1: h * 0.72, x2: w / 2, y2: h * 0.28, duration: 0.25)
                    }
                    usleep(280 * 1000)
                }
                let snap = try snapshot()
                if let el = snap.resolve(sel), el.onScreen { return Reply(ok: true, text: "visible \(snap.line(el))") }
                return Reply(ok: false, text: "could not scroll to \(sel)")

            case "clear" where !a.isEmpty:
                let sel = a[0]
                let el = currentForResolve().resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                if el != nil { try sim.tap(x: Double(el!.cx), y: Double(el!.cy)); usleep(150 * 1000) }
                try sim.setValue("", identifier: ident, label: label)
                settle()
                return Reply(ok: true, text: "cleared \(sel)")

            case "find" where !a.isEmpty:
                let snap = try snapshot()
                let hits = snap.find(a.joined(separator: " "))
                if hits.isEmpty { return Reply(ok: false, text: "no match") }
                return Reply(ok: true, text: hits.map(snap.line).joined(separator: "\n"))

            case "tap":
                if a.count >= 2, Double(a[0]) != nil, Double(a[1]) != nil {
                    try sim.tap(x: num(0), y: num(1)); settle()
                    return Reply(ok: true, text: "tapped @\(Int(num(0))),\(Int(num(1)))")
                }
                let sel = a.joined(separator: " ")
                if let el = currentForResolve().resolve(sel) {
                    try sim.tap(x: Double(el.cx), y: Double(el.cy)); settle()
                    return Reply(ok: true, text: "tapped \(el.ref) \(el.shortRole) \(el.label ?? el.id ?? "")")
                }
                // Fallback: tap visible text via OCR (no accessibility needed).
                if let (x, y, text) = ocrCenter(matching: Daemon.clean(sel)) {
                    try sim.tap(x: x, y: y); settle()
                    return Reply(ok: true, text: "tapped (ocr) \"\(text)\" @\(Int(x)),\(Int(y))")
                }
                return Reply(ok: false, text: "not found: \(sel)")

            case "tapocr" where !a.isEmpty:
                let q = Daemon.clean(a.joined(separator: " "))
                guard let (x, y, text) = ocrCenter(matching: q) else {
                    return Reply(ok: false, text: "no visible text matching: \(q)")
                }
                try sim.tap(x: x, y: y); settle()
                return Reply(ok: true, text: "tapped (ocr) \"\(text)\" @\(Int(x)),\(Int(y))")

            case "type" where !a.isEmpty:
                try sim.type(a.joined(separator: " ")); settle()
                return Reply(ok: true, text: "typed")

            case "typein" where a.count >= 2:
                guard let el = currentForResolve().resolve(a[0]) else {
                    return Reply(ok: false, text: "not found: \(a[0])")
                }
                try sim.tap(x: Double(el.cx), y: Double(el.cy)); usleep(200 * 1000)
                try sim.type(a[1...].joined(separator: " ")); settle()
                return Reply(ok: true, text: "typed into \(el.ref)")

            case "key" where !a.isEmpty:
                try sim.pressKey(usage: Int32(Double(a[0]) ?? 0)); settle()
                return Reply(ok: true, text: "key \(a[0])")

            case "swipe" where a.count >= 4:
                try sim.swipe(x1: num(0), y1: num(1), x2: num(2), y2: num(3), duration: 0.3); settle()
                return Reply(ok: true, text: "swiped")

            case "drag", "dragdrop":
                let hold = (cmd == "dragdrop") ? 0.7 : 0.0
                if a.count >= 4, Double(a[0]) != nil {
                    try sim.drag(x1: num(0), y1: num(1), x2: num(2), y2: num(3), hold: hold, move: 0.5)
                } else if a.count >= 2, let from = center(a[0]), let to = center(a[1]) {
                    try sim.drag(x1: from.0, y1: from.1, x2: to.0, y2: to.1, hold: hold, move: 0.5)
                } else {
                    return Reply(ok: false, text: "drag needs <x1 y1 x2 y2> or <fromSel toSel>")
                }
                settle()
                return Reply(ok: true, text: cmd == "dragdrop" ? "drag-and-dropped" : "dragged")

            case "longpress" where !a.isEmpty:
                if a.count >= 2, Double(a[0]) != nil {
                    try sim.longPress(x: num(0), y: num(1), duration: a.count >= 3 ? num(2) : 1.0)
                } else if let p = center(a[0]) {
                    try sim.longPress(x: p.0, y: p.1, duration: 1.0)
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return Reply(ok: true, text: "long-pressed")

            case "pinch" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.pinch(x: num(0), y: num(1), scale: num(2), duration: 0.5)
                } else if let p = center(a[0]) {
                    try sim.pinch(x: p.0, y: p.1, scale: Double(a[1]) ?? 2.0, duration: 0.5)
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return Reply(ok: true, text: "pinched")

            case "rotate" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.rotate(x: num(0), y: num(1), radians: num(2), duration: 0.5)
                } else if let p = center(a[0]) {
                    try sim.rotate(x: p.0, y: p.1, radians: Double(a[1]) ?? 0, duration: 0.5)
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return Reply(ok: true, text: "rotated")

            case "crown" where !a.isEmpty:
                // watchOS Digital Crown. Two forms:
                //   crown up|down [clicks]   — N discrete detents (predictable, linear)
                //   crown <delta> [steps]    — one raw turn (sign = direction; power users)
                // Crown scrolling has momentum, so "clicks" are emitted as separate small
                // turns with a settle gap rather than one large delta (which accelerates).
                let dir = a[0].lowercased()
                if dir == "up" || dir == "down" {
                    let clicks = a.count >= 2 ? max(1, Int(a[1]) ?? 1) : 1
                    let detent = 40.0                       // ≈ one comfortable notch (~1–1.5 rows)
                    let delta = (dir == "down") ? detent : -detent   // down = toward end of content
                    for _ in 0..<clicks {
                        try sim.turnCrown(by: delta, steps: 8, duration: 0.10)
                        usleep(120 * 1000)                  // let each detent settle (kills momentum)
                    }
                    settle(maxMs: 3000)
                    return Reply(ok: true, text: "crown \(dir) \(clicks)")
                }
                let delta = Double(a[0]) ?? 0
                let steps = a.count >= 2 ? (UInt(a[1]) ?? 24) : 24
                try sim.turnCrown(by: delta, steps: steps, duration: 0.25)
                settle(maxMs: 3000)
                return Reply(ok: true, text: "crowned \(delta)")

            case "scroll" where !a.isEmpty:
                // Universal scroll via a center swipe-drag. Works on EVERY device and
                // screen size, including watch sims whose guest ignores the Digital
                // Crown HID (e.g. the 40mm Apple Watch SE). Use this as the default
                // scroll verb; use `crown` only when you specifically need the
                // hardware Digital Crown. `clicks` = number of drags (default 1).
                let sdir = a[0].lowercased()
                guard sdir == "up" || sdir == "down" else { return Reply(ok: false, text: "scroll up|down [clicks]") }
                let clicks = a.count >= 2 ? max(1, Int(a[1]) ?? 1) : 1
                let w = Double(sim.screenPointSize.width)
                let h = Double(sim.screenPointSize.height)
                for _ in 0..<clicks {
                    // down = reveal content below = finger drags upward
                    if sdir == "down" {
                        try sim.swipe(x1: w / 2, y1: h * 0.72, x2: w / 2, y2: h * 0.30, duration: 0.25)
                    } else {
                        try sim.swipe(x1: w / 2, y1: h * 0.30, x2: w / 2, y2: h * 0.72, duration: 0.25)
                    }
                    usleep(150 * 1000)
                }
                settle()
                return Reply(ok: true, text: "scroll \(sdir) \(clicks)")

            case "screenshot":
                let path = a.first ?? "\(Net.socketDir())/last.png"
                try sim.screenshot(toPath: path)
                return Reply(ok: true, text: path)

            case "see":
                let obs = try sim.recognizeText()
                if obs.isEmpty { return Reply(ok: true, text: "(no text recognized)") }
                let lines = obs.compactMap { o -> String? in
                    guard let t = o["text"] as? String,
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return nil }
                    return "\"\(t)\" @\(Int(x + w / 2)),\(Int(y + h / 2))"
                }
                return Reply(ok: true, text: "\(lines.count) text regions (OCR)\n" + lines.joined(separator: "\n"))

            case "setvalue" where a.count >= 2:
                let sel = a[0]
                let text = a[1...].joined(separator: " ")
                let el = currentForResolve().resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                if el != nil { try sim.tap(x: Double(el!.cx), y: Double(el!.cy)); usleep(150 * 1000) }
                try sim.setValue(text, identifier: ident, label: label)
                settle()
                return Reply(ok: true, text: "set value of \(sel)")

            case "assert" where !a.isEmpty:
                let snap = try snapshot()
                let sel = a[0]
                let cond = a.count >= 2 ? a[1] : "exists"
                let el = snap.resolve(sel)
                if cond == "gone" {
                    return el == nil ? Reply(ok: true, text: "PASS gone \(sel)") : Reply(ok: false, text: "FAIL still present \(sel)")
                }
                if cond.hasPrefix("value=") {
                    let want = String(cond.dropFirst(6))
                    let got = el?.value ?? ""
                    return got == want ? Reply(ok: true, text: "PASS value \(want)") : Reply(ok: false, text: "FAIL value got \"\(got)\" want \"\(want)\"")
                }
                if cond.hasPrefix("label=") {
                    let want = String(cond.dropFirst(6))
                    let got = el?.label ?? ""
                    return got == want ? Reply(ok: true, text: "PASS label \(want)") : Reply(ok: false, text: "FAIL label got \"\(got)\" want \"\(want)\"")
                }
                return el != nil ? Reply(ok: true, text: "PASS exists \(snap.line(el!))") : Reply(ok: false, text: "FAIL not found \(sel)")

            case "wait" where !a.isEmpty:
                let sel = a[0]
                let timeout = a.count >= 2 ? (Double(a[1]) ?? 5000) : 5000
                let start = Date()
                while Date().timeIntervalSince(start) * 1000 < timeout {
                    let snap = try snapshot()
                    if let el = snap.resolve(sel) { return Reply(ok: true, text: "appeared \(snap.line(el))") }
                    usleep(120 * 1000)
                }
                return Reply(ok: false, text: "timeout waiting for \(sel)")

            case "install" where !a.isEmpty:
                let (c, o) = Simctl.run(["install", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "installed \(a[0])" : o)

            case "launch" where !a.isEmpty:
                let (c, o) = Simctl.run(["launch", sim.udid] + a)
                if c == 0 { lastBundle = a[0] }
                return Reply(ok: c == 0, text: o.trimmingCharacters(in: .whitespacesAndNewlines))

            case "logs":
                var seconds = 20
                var bundle = lastBundle
                for x in a { if let n = Int(x) { seconds = n } else { bundle = x } }
                guard let b = bundle else { return Reply(ok: false, text: "no app launched yet — pass a bundle id: wand logs <bundle> [seconds]") }
                guard let exe = appExecutable(b) else { return Reply(ok: false, text: "app not installed: \(b)") }
                let (_, o) = Simctl.run(["spawn", sim.udid, "log", "show", "--style", "compact",
                                         "--last", "\(seconds)s", "--predicate", "process == \"\(exe)\""])
                let lines = o.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.contains("getpwuid_r did not find") }
                    .suffix(120).map { String($0.prefix(300)) }
                return Reply(ok: true, text: lines.isEmpty ? "(no logs for \(exe) in last \(seconds)s)" : lines.joined(separator: "\n"))

            case "crashes":
                let bundle = a.first ?? lastBundle
                let exe = bundle.flatMap { appExecutable($0) }
                let (path, body) = latestCrash(matching: exe)
                if path == nil { return Reply(ok: true, text: "(no crash reports\(exe.map { " for \($0)" } ?? ""))") }
                return Reply(ok: true, text: "\(path!)\n\n\(body)")

            case "terminate" where !a.isEmpty:
                let (c, o) = Simctl.run(["terminate", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "terminated \(a[0])" : o)

            case "apps":
                let ids = userApps()
                return Reply(ok: true, text: ids.isEmpty ? "(no user apps)" : ids.joined(separator: "\n"))

            case "open" where !a.isEmpty:
                let (c, o) = Simctl.run(["openurl", sim.udid, a[0]])
                return Reply(ok: c == 0, text: c == 0 ? "opened \(a[0])" : o)

            case "permission" where a.count >= 3:
                let (c, o) = Simctl.run(["privacy", sim.udid, a[0], a[1], a[2]])
                return Reply(ok: c == 0, text: c == 0 ? "\(a[0]) \(a[1]) for \(a[2])" : o)

            case "record" where !a.isEmpty:
                if a[0] == "start" {
                    if recorder != nil { return Reply(ok: false, text: "already recording") }
                    let path = a.count >= 2 ? a[1] : "\(Net.socketDir())/recording.mp4"
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                    p.arguments = ["simctl", "io", sim.udid, "recordVideo", "--codec=h264", "--force", path]
                    p.standardInput = FileHandle.nullDevice
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try p.run()
                    recorder = p; recorderPath = path
                    return Reply(ok: true, text: "recording -> \(path)")
                } else {
                    guard let p = recorder else { return Reply(ok: false, text: "not recording") }
                    p.interrupt(); p.waitUntilExit()
                    let path = recorderPath ?? ""
                    recorder = nil; recorderPath = nil
                    return Reply(ok: true, text: "saved \(path)")
                }

            case "stop":
                Reply.respondThenExit()
                return Reply(ok: true, text: "stopping")

            default:
                return Reply(ok: false, text: "unknown command: \(cmd)")
            }
        } catch {
            return Reply(ok: false, text: "error: \(error.localizedDescription)")
        }
    }
}

extension Daemon.Reply {
    static func respondThenExit() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exit(0) }
    }
}
