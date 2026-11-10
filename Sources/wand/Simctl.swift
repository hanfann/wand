import Foundation
import WandKit

// Thin wrapper over `xcrun simctl` for control-plane operations (boot, install,
// launch, …). simctl is Apple's own tool — not a third-party dependency.
enum Simctl {
    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String) {
        let timeout: TimeInterval
        switch args.first {
        case "bootstatus": timeout = 120
        case "install": timeout = 60
        case "terminate", "list", "getenv": timeout = 15
        default: timeout = 30
        }
        let result = ProcessRunner.run("/usr/bin/xcrun", ["simctl"] + args, timeout: timeout)
        return (result.status, result.output)
    }

    struct Device { let udid: String; let name: String; let state: String }

    static func bootedDevices() -> [Device] {
        let (_, out) = run(["list", "devices", "booted", "-j"])
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = obj["devices"] as? [String: Any] else { return [] }
        var result: [Device] = []
        for (_, list) in devices {
            guard let arr = list as? [[String: Any]] else { continue }
            for d in arr {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                result.append(Device(udid: udid, name: name, state: (d["state"] as? String) ?? "?"))
            }
        }
        return result
    }

    // All devices (any state), for `boot`/listing by name.
    static func allDevices() -> [Device] {
        let (_, out) = run(["list", "devices", "-j"])
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = obj["devices"] as? [String: Any] else { return [] }
        var result: [Device] = []
        for (_, list) in devices {
            guard let arr = list as? [[String: Any]] else { continue }
            for d in arr {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String,
                      (d["isAvailable"] as? Bool) ?? true else { continue }
                result.append(Device(udid: udid, name: name, state: (d["state"] as? String) ?? "?"))
            }
        }
        return result
    }

    // Resolve the target sim: explicit > WAND_UDID env > the single booted device.
    static func resolveUDID(_ explicit: String?) -> String? {
        // Simulator identities become local socket filenames. Never accept path components.
        func valid(_ value: String) -> String? {
            guard !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return nil }
            return UUID(uuidString: value)?.uuidString ?? value
        }
        if let explicit { return valid(explicit) }
        if let env = ProcessInfo.processInfo.environment["WAND_UDID"], !env.isEmpty { return valid(env) }
        let booted = bootedDevices()
        return booted.count == 1 ? booted[0].udid : nil
    }
}
