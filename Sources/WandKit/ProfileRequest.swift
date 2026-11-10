import Foundation

public struct ProfileRequest {
    public let command: [String]
    public init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let command = try JSONSerialization.jsonObject(with: data) as? [String],
              let name = command.first, CommandBatch.allowed.contains(name) || name == "batch" else {
            throw NSError(domain: "wand.profile", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "profile expects one JSON command array; nested profiles and daemon/device lifecycle commands are not allowed"])
        }
        try CommandValidation.validate(command)
        self.command = command
    }
}
