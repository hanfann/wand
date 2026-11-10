import Foundation
import Darwin
import WandEngine
import WandKit

final class AccessibilityService {
    private let worker: WorkerProcess
    private var unavailableUntil: TimeInterval = 0
    var cancelled: (() -> Bool)?
    init(udid: String) {
        worker = WorkerProcess(executable: Client.executablePath(), arguments: ["__ax", udid])
    }
    func tree(timeout: TimeInterval = 5) throws -> [[String: Any]] {
        let reply = try request(["operation": "tree"], timeout: timeout)
        guard let tree = reply["tree"] as? [[String: Any]] else { throw failure("invalid accessibility tree") }
        return tree
    }
    func setValue(_ value: String, identifier: String?, label: String?) throws {
        var message: [String: Any] = ["operation": "set", "value": value]
        message["identifier"] = identifier; message["label"] = label
        _ = try request(message, timeout: 5)
    }
    private func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard ProcessInfo.processInfo.systemUptime >= unavailableUntil else {
            throw failure("accessibility worker cooling down after failure; input and stop remain available")
        }
        let reply: [String: Any]
        do { reply = try worker.request(message, timeout: timeout, cancelled: cancelled) }
        catch {
            unavailableUntil = ProcessInfo.processInfo.systemUptime + 2
            throw failure("Accessibility \(error.localizedDescription). Coordinate input and stop remain available")
        }
        guard reply["ok"] as? Bool == true else { throw failure(reply["error"] as? String ?? "accessibility failed") }
        return reply
    }
    func stop() { worker.stop() }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "wand.ax", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func run(udid: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let monitor = WorkerLifetime.monitorParent()
        defer { monitor.cancel() }
        // Fault injection occurs inside the expendable worker, never the daemon.
        if ProcessInfo.processInfo.environment["WAND_TEST_AX_STALL"] == "1" {
            while true { pause() }
        }
        do {
            let sim = try WNDSimulator.withUDID(udid)
            let reader = LineReader(fd: STDIN_FILENO)
            while let line = reader.next() {
                autoreleasepool {
                    var response: [String: Any]
                    do {
                        guard let data = line.data(using: .utf8),
                              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw NSError(domain: "wand.ax", code: 1)
                        }
                        switch request["operation"] as? String {
                        case "tree": response = ["ok": true, "tree": try sim.accessibilityTree()]
                        case "set":
                            try sim.setValue(request["value"] as? String ?? "", identifier: request["identifier"] as? String, label: request["label"] as? String)
                            response = ["ok": true]
                        default: response = ["ok": false, "error": "unknown accessibility operation"]
                        }
                    } catch { response = ["ok": false, "error": error.localizedDescription] }
                    if let data = try? JSONSerialization.data(withJSONObject: response), let text = String(data: data, encoding: .utf8) {
                        Net.writeLine(STDOUT_FILENO, text)
                    }
                }
            }
            exit(0)
        } catch { exit(1) }
    }
}
