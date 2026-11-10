import Foundation

/// Preflight the entire sequence before its first action. A batch is ordered,
/// stops at its first failure, and is never implicitly replayed or rolled back.
public struct CommandBatch {
    public let commands: [[String]]
    public let summary: Bool
    public static let allowed: Set<String> = [
        "ping", "info", "ui", "find", "scrollto", "scrollTo", "clear", "tap", "tapocr",
        "type", "typein", "key", "swipe", "drag", "dragdrop", "longpress", "pinch",
        "rotate", "crown", "scroll", "screenshot", "see", "setvalue", "assert", "wait",
        "install", "launch", "logs", "crashes", "terminate", "apps", "open", "permission", "record"
    ]
    public init(arguments: [String]) throws {
        if arguments.count == 1 {
            try self.init(json: arguments[0])
        } else if arguments.count == 2 && arguments[0] == "--summary" {
            try self.init(json: arguments[1], summary: true)
        } else {
            throw NSError(domain: "wand.batch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "batch expects [--summary] followed by a JSON array of command arrays"])
        }
    }

    public init(json: String, summary: Bool = false) throws {
        guard let data = json.data(using: .utf8),
              let commands = try JSONSerialization.jsonObject(with: data) as? [[String]],
              (1...64).contains(commands.count),
              commands.allSatisfy({ !$0.isEmpty && Self.allowed.contains($0[0]) }) else {
            throw NSError(domain: "wand.batch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "batch needs 1–64 command arrays of strings; nested batches, stop and unknown commands are not allowed"])
        }
        for command in commands { try CommandValidation.validate(command) }
        self.commands = commands
        self.summary = summary
    }
}
