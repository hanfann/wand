import Foundation
import Darwin
import WandKit

extension Daemon {
    func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        if let activeProfile { return try activeProfile.measure(name, body) }
        return try body()
    }

    func executeProfile(_ json: String) throws -> Reply {
        let request = try ProfileRequest(json: json)
        let profile = PhaseProfile()
        activeProfile = profile
        ocr.profile = profile
        defer { activeProfile = nil; ocr.profile = nil }
        return Self.profileReply(profile: profile) { execute(request.command) }
    }

    static func profileReply(profile: PhaseProfile, execute: () -> Reply) -> Reply {
        func cpuTime() -> Double {
            var value = timespec()
            guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
            return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
        }
        let cpuStart = cpuTime()
        let reply = execute()
        var metrics = profile.json
        metrics["daemon_cpu_ms"] = max(0, cpuTime() - cpuStart) * 1000
        metrics["result_bytes"] = reply.text.utf8.count
        let value: [String: Any] = ["schema": 1, "ok": reply.ok, "result": reply.text, "profile": metrics]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Reply(ok: false, text: "could not encode profile; command may have applied; do not replay", exitAfterReply: reply.exitAfterReply)
        }
        return Reply(ok: reply.ok, text: String(decoding: data, as: UTF8.self), exitAfterReply: reply.exitAfterReply)
    }
}
