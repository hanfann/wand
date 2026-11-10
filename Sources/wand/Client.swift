import Foundation
import Darwin
import WandKit

enum Client {
    // Returned by the daemon when its bound boot session is stale (the simulator
    // was rebooted/erased under it). The client respawns a fresh daemon and
    // retries transparently — in-process rebinding does not work; only a new
    // process re-establishes the CoreSimulator connection.
    static let staleSentinel = "__WAND_STALE_SESSION__"

    // The device's launchd_sim PID(s) — stable within a boot, replaced on reboot.
    // Used as a boot-session token so the daemon can detect it went stale.
    static func deviceBootPids(_ udid: String) -> [Int32] {
        let result = ProcessRunner.run("/bin/ps", ["-axo", "pid=,comm=,args="], timeout: 5)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { row in
            // comm can contain spaces; locate launchd_sim's command boundary.
            guard let marker = row.range(of: "launchd_sim "),
                  row[marker.upperBound...].contains(udid),
                  let pid = row.split(whereSeparator: \.isWhitespace).first else { return nil }
            let executable = row[..<marker.upperBound].trimmingCharacters(in: .whitespaces)
            guard executable.hasSuffix("/launchd_sim") else { return nil }
            return Int32(pid)
        }
    }

    static func executablePath() -> String {
        // The real running binary — reliable however we were invoked (bare PATH
        // name, relative, or absolute). argv[0] is not trustworthy here.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            return (String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) as NSString).resolvingSymlinksInPath
        }
        let arg0 = CommandLine.arguments[0]
        let abs = (arg0 as NSString).isAbsolutePath
            ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
        return (abs as NSString).resolvingSymlinksInPath
    }

    static func sendOnce(_ udid: String, _ argv: [String], timeout: TimeInterval = 300,
                         cancellation: CommandCancellation? = nil) -> (Bool, String)? {
        if cancellation?.isCancelled == true { return (false, "cancelled before dispatch; no input sent") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd = Net.connect(Net.socketPath(udid), timeout: min(1, timeout))
        if fd < 0 { return nil }
        defer { close(fd) }
        guard let data = try? JSONSerialization.data(withJSONObject: argv),
              let s = String(data: data, encoding: .utf8) else { return (false, "cannot encode command") }
        guard cancellation?.beginDispatch() != false else {
            return (false, "cancelled before dispatch; no input sent")
        }
        let cancelled: (() -> Bool)? = cancellation.map { token in { token.isCancelled } }
        guard Net.writeLine(fd, s, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), cancelled: cancelled),
              let resp = Net.readLine(fd, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime), cancelled: cancelled),
              let rd = resp.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any]
        else {
            // A connected request may have executed before its reply was lost.
            // Never replay an ambiguous tap or batch.
            return (false, "daemon reply missing, invalid or timed out after sending; command may have run. Inspect the screen before retrying")
        }
        return ((obj["ok"] as? Bool) ?? false, (obj["text"] as? String) ?? "")
    }

    static func spawnDaemon(_ udid: String) throws -> Process {
        let log = "\(Net.socketDir())/daemon-\(udid).log"
        if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
        let out = FileHandle(forWritingAtPath: log)
        _ = try? out?.seekToEnd()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath())
        p.arguments = ["__daemon"]
        var env = ProcessInfo.processInfo.environment
        env["WAND_UDID"] = udid
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out ?? FileHandle.nullDevice
        p.standardError = out ?? FileHandle.nullDevice
        try p.run()
        try? out?.close()
        return p
    }

    static func send(_ udid: String, _ argv: [String], cancellation: CommandCancellation? = nil) -> (Bool, String) {
        guard Net.socketPath(udid).utf8.count < 104 else {
            return (false, "simulator socket path is too long; use a canonical UDID")
        }
        let replyTimeout: TimeInterval = argv.first == "stop" ? 6 : 300
        if let r = sendOnce(udid, argv, timeout: replyTimeout, cancellation: cancellation), r.1 != staleSentinel { return r }
        let testMs = ProcessInfo.processInfo.environment["WAND_TEST_STARTUP_TIMEOUT_MS"].flatMap(Double.init)
        let deadline = ProcessInfo.processInfo.systemUptime + min(20, max(0.1, (testMs ?? 20000) / 1000))
        _ = Maintenance.run(automatic: true)
        let startupLock = open(Net.socketPath(udid) + ".startup.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard startupLock >= 0 else { return (false, "cannot open daemon startup lock") }
        defer { flock(startupLock, LOCK_UN); close(startupLock) }
        while flock(startupLock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return (false, "cannot lock daemon startup") }
            if cancellation?.isCancelled == true { return (false, "cancelled during startup; no input sent") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return (false, "daemon startup lock deadline exceeded; no input sent") }
            usleep(20_000)
        }
        // Another starter may have finished while this client waited for the lock.
        if let r = sendOnce(udid, ["ping"], timeout: min(0.5, max(0, deadline - ProcessInfo.processInfo.systemUptime))), r.0 {
            return sendOnce(udid, argv, timeout: replyTimeout, cancellation: cancellation) ?? (false, "daemon disappeared before dispatch")
        }
        let child: Process
        do { child = try spawnDaemon(udid) }
        catch { return (false, "cannot launch daemon: \(error.localizedDescription)") }
        var ready = false
        defer {
            // Only our unready child is terminated. Never kill an existing owner.
            if !ready, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation?.isCancelled == true { return (false, "cancelled during startup; no input sent") }
            guard child.isRunning else { return (false, "daemon exited before readiness; see ~/.wand/daemon-\(udid).log") }
            if let reply = sendOnce(udid, ["ping"], timeout: min(0.25, max(0, deadline - ProcessInfo.processInfo.systemUptime))), reply.0 {
                ready = true
                return sendOnce(udid, argv, timeout: replyTimeout, cancellation: cancellation) ?? (false, "daemon disappeared before dispatch")
            }
            usleep(20_000)
        }
        return (false, "daemon startup deadline exceeded; unready child stopped; no input sent; see ~/.wand/daemon-\(udid).log")
    }

    static func daemonRunning(_ udid: String) -> Bool {
        let fd = Net.connect(Net.socketPath(udid))
        if fd < 0 { return false }
        close(fd)
        return true
    }
}
