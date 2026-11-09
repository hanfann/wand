import Foundation
import Darwin

enum Client {
    // Returned by the daemon when its bound boot session is stale (the simulator
    // was rebooted/erased under it). The client respawns a fresh daemon and
    // retries transparently — in-process rebinding does not work; only a new
    // process re-establishes the CoreSimulator connection.
    static let staleSentinel = "__WAND_STALE_SESSION__"

    // The device's launchd_sim PID(s) — stable within a boot, replaced on reboot.
    // Used as a boot-session token so the daemon can detect it went stale.
    static func deviceBootPids(_ udid: String) -> [Int32] {
        func run(_ path: String, _ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        }
        let pids = run("/usr/bin/pgrep", ["-f", udid])
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return pids.filter {
            run("/bin/ps", ["-o", "comm=", "-p", "\($0)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("launchd_sim")
        }
    }

    static func executablePath() -> String {
        // The real running binary — reliable however we were invoked (bare PATH
        // name, relative, or absolute). argv[0] is not trustworthy here.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            return (String(cString: buf) as NSString).resolvingSymlinksInPath
        }
        let arg0 = CommandLine.arguments[0]
        let abs = (arg0 as NSString).isAbsolutePath
            ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
        return (abs as NSString).resolvingSymlinksInPath
    }

    static func sendOnce(_ udid: String, _ argv: [String]) -> (Bool, String)? {
        let fd = Net.connect(Net.socketPath(udid))
        if fd < 0 { return nil }
        defer { close(fd) }
        guard let data = try? JSONSerialization.data(withJSONObject: argv),
              let s = String(data: data, encoding: .utf8) else { return nil }
        Net.writeLine(fd, s)
        guard let resp = Net.readLine(fd),
              let rd = resp.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any]
        else { return nil }
        return ((obj["ok"] as? Bool) ?? false, (obj["text"] as? String) ?? "")
    }

    static func spawnDaemon(_ udid: String) {
        let log = "\(Net.socketDir())/daemon-\(udid).log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let out = FileHandle(forWritingAtPath: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath())
        p.arguments = ["__daemon"]
        var env = ProcessInfo.processInfo.environment
        env["WAND_UDID"] = udid
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out ?? FileHandle.nullDevice
        p.standardError = out ?? FileHandle.nullDevice
        try? p.run()
    }

    static func send(_ udid: String, _ argv: [String]) -> (Bool, String) {
        // Healthy daemon → use it. A stale-session sentinel is treated like "no
        // daemon": respawn a fresh process and retry the same command.
        if let r = sendOnce(udid, argv), r.1 != staleSentinel { return r }
        // Concurrent clients must not each spawn a daemon for the same watch.
        let startupLock = open(Net.socketPath(udid) + ".startup.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard startupLock >= 0, flock(startupLock, LOCK_EX) == 0 else {
            if startupLock >= 0 { close(startupLock) }
            return (false, "cannot lock daemon startup")
        }
        defer { flock(startupLock, LOCK_UN); close(startupLock) }
        if let r = sendOnce(udid, argv), r.1 != staleSentinel { return r }
        usleep(200 * 1000)  // let the exiting stale daemon release the socket
        spawnDaemon(udid)
        for _ in 0..<200 {  // up to ~20s for cold framework warmup
            usleep(100 * 1000)
            if let r = sendOnce(udid, argv), r.1 != staleSentinel { return r }
        }
        return (false, "daemon did not start (see ~/.wand/daemon-\(udid).log)")
    }

    static func daemonRunning(_ udid: String) -> Bool {
        let fd = Net.connect(Net.socketPath(udid))
        if fd < 0 { return false }
        close(fd)
        return true
    }
}
