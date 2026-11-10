import Foundation

// App metadata and diagnostic formatting, separate from serialized UI input.
extension Daemon {
    // The app's executable (process) name, from its installed Info.plist.
    func appExecutable(_ bundle: String) -> String? {
        let (c, path) = Simctl.run(["get_app_container", sim.udid, bundle, "app"])
        guard c == 0 else { return nil }
        let plist = path.trimmingCharacters(in: .whitespacesAndNewlines) + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty else { return nil }
        return exe
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

    // Decode simctl's app plist directly, without a shared tempfile or plutil process.
    func userApps() throws -> [String] {
        let (code, o) = Simctl.run(["listapps", sim.udid])
        guard code == 0 else {
            throw NSError(domain: "wand.apps", code: Int(code), userInfo: [NSLocalizedDescriptionKey: o])
        }
        guard let data = o.data(using: .utf8),
              let obj = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw NSError(domain: "wand.apps", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not decode installed app list"])
        }
        return obj.compactMap { (bid, v) -> String? in
            guard let dict = v as? [String: Any], (dict["ApplicationType"] as? String) == "User" else { return nil }
            return bid
        }.sorted()
    }

}
