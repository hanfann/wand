import Foundation
import ImageIO
import WandKit

/// Prepare an explicitly requested final screenshot before ANY batch input runs.
/// Attachment reads are confined to that screenshot's full/preview destinations.
struct MCPImageRequest {
    let command: [String]
    let fullPath: String
    private let finalStep: Int?
    private let since: String

    init(command: [String], defaultPath: String) throws {
        let batch = command.first == "batch" ? try CommandBatch(arguments: Array(command.dropFirst())) : nil
        var steps = batch?.commands ?? [command]
        guard let last = steps.last, last.first == "screenshot" else {
            throw Self.failure("image=true requires a final screenshot command")
        }
        let options = try ScreenshotOptions(arguments: Array(last.dropFirst()))
        since = options.since ?? "none"
        fullPath = URL(fileURLWithPath: options.path ?? defaultPath).standardizedFileURL.path
        var screenshot = ["screenshot", fullPath, "--preview", String(options.maxEdge ?? 640)]
        if let crop = options.crop { screenshot += ["--crop", String(crop.x), String(crop.y), String(crop.width), String(crop.height)] }
        screenshot += ["--since", since]
        steps[steps.count - 1] = screenshot
        if let batch {
            let data = try JSONSerialization.data(withJSONObject: steps)
            self.command = ["batch"] + (batch.summary ? ["--summary"] : []) + [String(decoding: data, as: UTF8.self)]
            finalStep = steps.count
        } else {
            self.command = screenshot
            finalStep = nil
        }
    }

    func attachment(reply: String) throws -> [String: Any]? {
        let payload: Substring
        if let finalStep {
            let prefix = "\(finalStep) OK "
            if finalStep == 1, reply.hasPrefix(prefix) {
                payload = reply.dropFirst(prefix.count)
            } else if let range = reply.range(of: "\n" + prefix, options: .backwards) {
                payload = reply[range.upperBound...]
            } else { throw Self.failure("missing final screenshot result") }
        } else { payload = reply[...] }
        guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let returnedFull = value["full"] as? String,
              URL(fileURLWithPath: returnedFull).standardizedFileURL.path == fullPath,
              let changed = value["changed"] as? Bool,
              let token = value["token"] as? String,
              (try? ScreenshotOptions(arguments: ["--since", token])) != nil,
              token != "none", changed == (token != since) else {
            throw Self.failure("invalid screenshot observation")
        }
        if !changed { return nil }
        let expectedPreview = URL(fileURLWithPath: fullPath).deletingPathExtension().path + ".preview.png"
        guard let preview = value["preview"] as? String,
              [fullPath, expectedPreview].contains(URL(fileURLWithPath: preview).standardizedFileURL.path) else {
            throw Self.failure("unexpected screenshot destination")
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: preview))
        defer { try? file.close() }
        let limit = 2 * 1024 * 1024
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else {
            throw Self.failure("image is invalid or exceeds 2 MiB/4096px; request a smaller preview")
        }
        return ["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()]
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "wand.mcp.image", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
