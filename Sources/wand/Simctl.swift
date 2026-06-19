import Foundation

// Thin wrapper over `xcrun simctl` for control-plane operations (boot, install,
// launch, …). simctl is Apple's own tool — not a third-party dependency.
enum Simctl {
    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "failed to run simctl: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
        if let e = explicit, !e.isEmpty { return e }
        if let env = ProcessInfo.processInfo.environment["WAND_UDID"], !env.isEmpty { return env }
        let booted = bootedDevices()
        return booted.count == 1 ? booted[0].udid : booted.first?.udid
    }
}
