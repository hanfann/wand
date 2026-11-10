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
    var referencesValid = false
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
    let ocr = OCRService()
    let accessibility: AccessibilityService
    private var activeClient: Int32 = -1

    // Commands that inject HID events; their replies are checked for send errors.
    static let inputCommands: Set<String> = [
        "tap", "tapocr", "type", "typein", "setvalue", "clear", "key",
        "swipe", "drag", "dragdrop", "longpress", "pinch", "rotate", "crown", "scroll", "scrollto", "scrollTo",
    ]

    static func acquireOwnership(udid: String) -> Int32 {
        let lock = open(Net.socketPath(udid) + ".owner.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(1) }
        return lock
    }

    init(sim: WNDSimulator, ownerLock: Int32) {
        self.ownerLock = ownerLock
        signal(SIGPIPE, SIG_IGN)
        self.sim = sim
        self.accessibility = AccessibilityService(udid: sim.udid)
        self.bootPids = Client.deviceBootPids(sim.udid)
        self.startupError = WNDSimulator.wireFormatError() ?? sim.readinessError()
    }

    // Stale if the device shut down, or if every launchd_sim we bound to is gone
    // (a reboot replaces it). Empty bootPids = couldn't determine → don't guess.
    func isSessionStale() -> Bool {
        if !sim.isBooted() { return true }
        if bootPids.isEmpty { return false }
        return !bootPids.contains { kill($0, 0) == 0 }
    }

    struct Reply { var ok: Bool; var text: String; var exitAfterReply = false }

    func serve(startupMonitor: DispatchSourceTimer? = nil) {
        let path = Net.socketPath(sim.udid)
        let fd = Net.listen(path)
        guard fd >= 0 else {
            FileHandle.standardError.write("wandd: cannot bind \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        // Once listening, the daemon intentionally outlives its launching client.
        // Before this point, a dead client must not leave a stalled startup owner.
        startupMonitor?.cancel()
        // Read accessibility on demand. Its first private call can stall during
        // simulator startup; info/launch/stop must remain usable without it.
        FileHandle.standardError.write("wandd: ready on \(path) [\(sim.name)]\n".data(using: .utf8)!)

        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            Net.configure(c)
            var shouldExit = false
            autoreleasepool {
                if let line = Net.readLine(c, timeout: 5) {
                    activeClient = c
                    accessibility.cancelled = { [weak self] in self?.clientDisconnected() ?? true }
                    ocr.cancelled = accessibility.cancelled
                    let reply = handle(line)
                    activeClient = -1
                    shouldExit = reply.exitAfterReply
                    if shouldExit {
                        // Release resources before acknowledging stop/stale, so
                        // an immediate restart cannot connect to a dying owner.
                        unlink(path)
                        close(fd)
                        accessibility.stop()
                        sim.closeInput()
                        stopRecorder()
                        flock(ownerLock, LOCK_UN)
                    }
                    let obj: [String: Any] = ["ok": reply.ok, "text": reply.text]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let s = String(data: data, encoding: .utf8) {
                        Net.writeLine(c, s)
                    }
                }
            }
            close(c)
            if shouldExit { exit(0) }
        }
    }

    private func clientDisconnected() -> Bool {
        guard activeClient >= 0 else { return false }
        var byte: UInt8 = 0
        return recv(activeClient, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private func checkCancellation() throws {
        if clientDisconnected() {
            throw NSError(domain: "wand.cancelled", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "client disconnected; remaining actions stopped; earlier input may have applied"])
        }
    }

    private func stopRecorder() {
        guard let process = recorder else { return }
        process.interrupt()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Foundation reaps asynchronously; shutdown must remain bounded.
        recorder = nil
    }

    // --- snapshot helpers ---

    func snapshot(timeout: TimeInterval = 5) throws -> Snapshot {
        let tree = try accessibility.tree(timeout: timeout)
        try sim.refreshDisplayGeometry()
        let snap = Snapshot(elements: tree,
                            screenW: Double(sim.screenPointSize.width),
                            screenH: Double(sim.screenPointSize.height))
        guard !snap.all.isEmpty else {
            throw NSError(domain: "wand.ax", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "accessibility returned no usable root; retry observation after the app is ready"])
        }
        last = snap
        referencesValid = true
        return snap
    }

    func currentForResolve(_ selector: String) throws -> Snapshot {
        if selector.hasPrefix("e"), Int(selector.dropFirst()) != nil {
            return referencesValid ? (last ?? Snapshot(elements: [])) : Snapshot(elements: [])
        }
        // IDs/labels resolve against current geometry. Positional refs require a
        // new explicit observation after an action, never silent reassignment.
        return try snapshot()
    }

    // Observe rendered stability without monopolizing/restarting the AX worker.
    // Slow private AX reads during animation must not turn successful input into
    // a cycle of worker kills and false "not found" errors.
    func settle(maxMs: Int = 1500) {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + Double(maxMs) / 1000
        let minimum = sim.isWatch ? 0.65 : 0.18
        var previous: UInt64 = 0, stableReads = 0
        while ProcessInfo.processInfo.systemUptime < deadline && !clientDisconnected() {
            let signature = sim.screenFingerprint()
            guard signature != 0 else { return }
            stableReads = signature == previous ? stableReads + 1 : 0
            if stableReads >= 2 && ProcessInfo.processInfo.systemUptime - start >= minimum { return }
            previous = signature
            usleep(90_000)
        }
    }

    // Resolve a selector to its element center (for gesture targeting by id/label).
    func center(_ sel: String) throws -> (Double, Double)? {
        guard let el = try currentForResolve(sel).resolve(sel) else { return nil }
        return (Double(el.cx), Double(el.cy))
    }

    // OCR fallback: find visible text on screen (works with no app accessibility).
    func ocrCenter(matching query: String) throws -> (Double, Double, String)? {
        let width = Double(sim.screenPointSize.width), height = Double(sim.screenPointSize.height)
        let fast = try ocr.recognize(sim: sim)
        do {
            if let hit = try OCRTarget.resolve(query, observations: fast, width: width, height: height,
                                               exactOnly: true, minConfidence: 0.8) {
                return (hit.x, hit.y, hit.text)
            }
        } catch OCRTarget.Failure.uncertain { /* Ask accurate OCR before accepting uncertain text. */ }
        // Ambiguous text never chooses an arbitrary occurrence. Accurate fallback
        // may time out on Apple's model initialization; fail without input then.
        let observations = try ocr.recognize(sim: sim, accurate: true)
        guard let hit = try OCRTarget.resolve(query, observations: observations, width: width, height: height) else { return nil }
        return (hit.x, hit.y, hit.text)
    }

    static func clean(_ sel: String) -> String {
        var s = sel
        if s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // --- command dispatch ---

    func handle(_ line: String) -> Reply {
        guard let data = line.data(using: .utf8),
              let argv = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return Reply(ok: false, text: "bad request")
        }
        return execute(argv)
    }

    // Single commands and batch steps share validation, dispatch and HID-error
    // handling. A batch stays in memory; only the socket boundary encodes JSON.
    func execute(_ argv: [String]) -> Reply {
        let reply = dispatch(argv)
        if reply.ok, let command = argv.first, Self.inputCommands.contains(command),
           let error = sim.lastSendError() {
            return Reply(ok: false, text: "input may not have landed (HID send error): \(error)")
        }
        return reply
    }

    private func dispatch(_ argv: [String]) -> Reply {
        guard let cmd = argv.first else { return Reply(ok: false, text: "bad request") }
        do { try CommandValidation.validate(argv) }
        catch { return Reply(ok: false, text: error.localizedDescription) }
        let a = Array(argv.dropFirst())
        func num(_ i: Int) -> Double { i < a.count ? (Double(a[i]) ?? 0) : 0 }

        // Unsupported input must fail loudly. Read-only diagnostics remain usable.
        if let e = startupError, Self.inputCommands.contains(cmd) {
            return Reply(ok: false, text: "wand: \(e)")
        }
        defer {
            if Self.inputCommands.contains(cmd) || ["launch", "terminate", "open"].contains(cmd) {
                referencesValid = false
            }
        }
        sim.clearLastSendError()

        do {
            // Resilience: if the bound simulator was shut down or rebooted, exit
            // cleanly and signal the client (via the sentinel) to respawn a fresh
            // daemon and retry — transparently self-healing across sim reboots.
            if cmd != "ping", cmd != "info", cmd != "stop", isSessionStale() {
                return Reply(ok: false, text: Client.staleSentinel, exitAfterReply: true)
            }
            if Self.inputCommands.contains(cmd) || ["info", "ui", "find", "wait", "assert", "see", "screenshot"].contains(cmd) {
                let previousOrientation = sim.displayOrientation, previousSize = sim.screenPointSize
                try sim.refreshDisplayGeometry()
                if previousOrientation != sim.displayOrientation || previousSize != sim.screenPointSize { referencesValid = false }
            }
            switch cmd {
            case "batch":
                guard a.count == 1 else { return Reply(ok: false, text: "batch needs a JSON array of command arrays") }
                let batch = try CommandBatch(json: a[0])
                var output: [String] = []
                for (index, command) in batch.commands.enumerated() {
                    if clientDisconnected() {
                        return Reply(ok: false, text: "client disconnected; remaining batch steps did not run; prior steps may have applied")
                    }
                    let reply = execute(command)
                    output.append("\(index + 1) \(reply.ok ? "OK" : "FAIL") \(reply.text)")
                    if !reply.ok {
                        output.append("stopped; remaining commands did not run. Inspect state before retrying")
                        return Reply(ok: false, text: output.joined(separator: "\n"), exitAfterReply: reply.exitAfterReply)
                    }
                }
                return Reply(ok: true, text: output.joined(separator: "\n"))

            case "ping":
                return Reply(ok: true, text: "pong \(sim.name)")

            case "info":
                return Reply(ok: true, text: "\(sim.name) [\(sim.udid)] \(Int(sim.screenPointSize.width))x\(Int(sim.screenPointSize.height))pt @\(sim.screenScale)x HID=\(sim.inputTransport)")

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
                    try checkCancellation()
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
                let el = try currentForResolve(sel).resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                if el != nil { try sim.tap(x: Double(el!.cx), y: Double(el!.cy)); usleep(150 * 1000) }
                try accessibility.setValue("", identifier: ident, label: label)
                settle()
                return Reply(ok: true, text: "cleared \(sel)")

            case "find" where !a.isEmpty:
                let snap = try snapshot()
                let hits = snap.find(a.joined(separator: " "))
                if hits.isEmpty { return Reply(ok: false, text: "no match") }
                return Reply(ok: true, text: hits.map(snap.line).joined(separator: "\n"))

            case "tap":
                guard !a.isEmpty else { return Reply(ok: false, text: "tap needs a selector or x y point") }
                if a.count >= 2, Double(a[0]) != nil, Double(a[1]) != nil {
                    try sim.tap(x: num(0), y: num(1)); settle()
                    return Reply(ok: true, text: "tapped @\(Int(num(0))),\(Int(num(1)))")
                }
                let sel = a.joined(separator: " ")
                if let el = try currentForResolve(sel).resolve(sel) {
                    try sim.tap(x: Double(el.cx), y: Double(el.cy)); settle()
                    return Reply(ok: true, text: "tapped \(el.ref) \(el.shortRole) \(el.label ?? el.id ?? "")")
                }
                if sel.hasPrefix("#") || (sel.hasPrefix("e") && Int(sel.dropFirst()) != nil) {
                    return Reply(ok: false, text: "accessibility target not found: \(sel). Refresh ui; identifiers are not visible text")
                }
                // Fallback: bounded OCR of visible labels only.
                if let (x, y, text) = try ocrCenter(matching: Daemon.clean(sel)) {
                    try sim.tap(x: x, y: y); settle()
                    return Reply(ok: true, text: "tapped (ocr) \"\(text)\" @\(Int(x)),\(Int(y))")
                }
                return Reply(ok: false, text: "not found: \(sel)")

            case "tapocr" where !a.isEmpty:
                let q = Daemon.clean(a.joined(separator: " "))
                guard let (x, y, text) = try ocrCenter(matching: q) else {
                    return Reply(ok: false, text: "no visible text matching: \(q)")
                }
                try sim.tap(x: x, y: y); settle()
                return Reply(ok: true, text: "tapped (ocr) \"\(text)\" @\(Int(x)),\(Int(y))")

            case "type" where !a.isEmpty:
                try sim.type(a.joined(separator: " ")); settle()
                return Reply(ok: true, text: "typed")

            case "typein" where a.count >= 2:
                guard let el = try currentForResolve(a[0]).resolve(a[0]) else {
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
                } else if a.count >= 2, let from = try center(a[0]), let to = try center(a[1]) {
                    try sim.drag(x1: from.0, y1: from.1, x2: to.0, y2: to.1, hold: hold, move: 0.5)
                } else {
                    return Reply(ok: false, text: "drag needs <x1 y1 x2 y2> or <fromSel toSel>")
                }
                settle()
                return Reply(ok: true, text: cmd == "dragdrop" ? "drag-and-dropped" : "dragged")

            case "longpress" where !a.isEmpty:
                if a.count >= 2, Double(a[0]) != nil {
                    try sim.longPress(x: num(0), y: num(1), duration: a.count >= 3 ? num(2) : 1.0)
                } else if let p = try center(a[0]) {
                    try sim.longPress(x: p.0, y: p.1, duration: a.count >= 2 ? num(1) : 1.0)
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return Reply(ok: true, text: "long-pressed")

            case "pinch" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.pinch(x: num(0), y: num(1), scale: num(2), duration: 0.5)
                } else if let p = try center(a[0]) {
                    try sim.pinch(x: p.0, y: p.1, scale: Double(a[1]) ?? 2.0, duration: 0.5)
                } else { return Reply(ok: false, text: "not found: \(a[0])") }
                settle()
                return Reply(ok: true, text: "pinched")

            case "rotate" where a.count >= 2:
                if a.count >= 3, Double(a[0]) != nil {
                    try sim.rotate(x: num(0), y: num(1), radians: num(2), duration: 0.5)
                } else if let p = try center(a[0]) {
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
                    let clicks = a.count >= 2 ? Int(Double(a[1]) ?? 1) : 1
                    let detent = 40.0                       // ≈ one comfortable notch (~1–1.5 rows)
                    let delta = (dir == "down") ? detent : -detent   // down = toward end of content
                    for _ in 0..<clicks {
                        try checkCancellation()
                        try sim.turnCrown(by: delta, steps: 8, duration: 0.10)
                        usleep(120 * 1000)                  // let each detent settle (kills momentum)
                    }
                    settle(maxMs: 3000)
                    return Reply(ok: true, text: "crown \(dir) \(clicks)")
                }
                let delta = Double(a[0]) ?? 0
                let steps = a.count >= 2 ? UInt(Double(a[1]) ?? 24) : 24
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
                let clicks = a.count >= 2 ? Int(Double(a[1]) ?? 1) : 1
                let w = Double(sim.screenPointSize.width)
                let h = Double(sim.screenPointSize.height)
                for _ in 0..<clicks {
                        try checkCancellation()
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
                let accurate = a.first == "accurate"
                let query = (accurate ? Array(a.dropFirst()) : a).joined(separator: " ").lowercased()
                let obs = try ocr.recognize(sim: sim, accurate: accurate).filter {
                    query.isEmpty || (($0["text"] as? String)?.lowercased().contains(query) ?? false)
                }
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
                let el = try currentForResolve(sel).resolve(sel)
                let ident = el?.id ?? (sel.hasPrefix("#") ? String(sel.dropFirst()) : nil)
                let label = el?.label ?? (!sel.hasPrefix("#") && !sel.hasPrefix("e") ? sel : nil)
                // AX sets and focuses the field itself. Tapping first can raise
                // a keyboard that hides the target before AX can resolve it.
                try accessibility.setValue(text, identifier: ident, label: label)
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
                    return el != nil && got == want ? Reply(ok: true, text: "PASS value \(want)") : Reply(ok: false, text: "FAIL value got \"\(got)\" want \"\(want)\"")
                }
                if cond.hasPrefix("label=") {
                    let want = String(cond.dropFirst(6))
                    let got = el?.label ?? ""
                    return el != nil && got == want ? Reply(ok: true, text: "PASS label \(want)") : Reply(ok: false, text: "FAIL label got \"\(got)\" want \"\(want)\"")
                }
                return el != nil ? Reply(ok: true, text: "PASS exists \(snap.line(el!))") : Reply(ok: false, text: "FAIL not found \(sel)")

            case "wait" where !a.isEmpty:
                let sel = a[0]
                let timeout = a.count >= 2 ? (Double(a[1]) ?? 5000) : 5000
                let deadline = ProcessInfo.processInfo.systemUptime + timeout / 1000
                var lastObservationError: String?
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try checkCancellation()
                    do {
                        let snap = try snapshot(timeout: min(5, max(0.01, deadline - ProcessInfo.processInfo.systemUptime)))
                        lastObservationError = nil
                        if let el = snap.resolve(sel) { return Reply(ok: true, text: "appeared \(snap.line(el))") }
                    } catch {
                        // A newly launched app can briefly have no AX root. That
                        // is a pending observation, not an immediate wait failure.
                        lastObservationError = error.localizedDescription
                    }
                    usleep(120 * 1000)
                }
                let detail = lastObservationError.map { "; last observation: \($0)" } ?? ""
                return Reply(ok: false, text: "timeout waiting for \(sel)" + detail)

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
                let (code, o) = Simctl.run(["spawn", sim.udid, "log", "show", "--style", "compact",
                                         "--last", "\(seconds)s", "--predicate", "process == \"\(exe)\""])
                guard code == 0 else { return Reply(ok: false, text: o) }
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
                let ids = try userApps()
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
                    guard recorder != nil else { return Reply(ok: false, text: "not recording") }
                    stopRecorder()
                    let path = recorderPath ?? ""
                    recorder = nil; recorderPath = nil
                    return Reply(ok: true, text: "saved \(path)")
                }

            case "stop":
                return Reply(ok: true, text: "stopping", exitAfterReply: true)

            default:
                return Reply(ok: false, text: "unknown command: \(cmd)")
            }
        } catch {
            return Reply(ok: false, text: "error: \(error.localizedDescription)")
        }
    }
}
