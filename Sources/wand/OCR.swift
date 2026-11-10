import CryptoKit
import Foundation
import ImageIO
import Vision
import WandEngine
import WandKit
import Darwin

// Vision can hang during model initialization. Run it outside the input daemon
// with a deadline so screenshots, taps and stop remain available after a stall.
final class OCRService {
    var cancelled: (() -> Bool)?
    private var cachedKey: String?
    private var cached: [[String: Any]] = []

    func recognize(sim: WNDSimulator, accurate: Bool = false) throws -> [[String: Any]] {
        let prefix = Net.socketDir() + "/ocr-" + UUID().uuidString
        let imagePath = prefix + ".png", resultPath = prefix + ".json"
        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
            try? FileManager.default.removeItem(atPath: resultPath)
        }
        try sim.screenshot(toPath: imagePath)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            + "|\(sim.screenPointSize)|\(accurate)"
        if key == cachedKey { return cached }

        FileManager.default.createFile(atPath: resultPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let result = try FileHandle(forWritingTo: URL(fileURLWithPath: resultPath))
        defer { try? result.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Client.executablePath())
        process.arguments = ["__ocr", imagePath, String(Double(sim.screenPointSize.width)),
                             String(Double(sim.screenPointSize.height)), accurate ? "accurate" : "fast"]
        process.standardOutput = result
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + (accurate ? 5 : 3)
        while process.isRunning && cancelled?() != true && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(50_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw failure("OCR timed out or was cancelled; input daemon remains usable. Use screenshot and point coordinates")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: resultPath))
        guard process.terminationStatus == 0,
              let observations = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw failure("OCR failed; use screenshot and point coordinates")
        }
        cachedKey = key
        cached = observations
        return observations
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "wand.ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func worker(_ args: [String]) -> Never {
        let monitor = WorkerLifetime.monitorParent()
        defer { monitor.cancel() }
        if ProcessInfo.processInfo.environment["WAND_TEST_OCR_STALL"] == "1" { while true { pause() } }
        guard args.count == 4, let w = Double(args[1]), let h = Double(args[2]),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
        let request = VNRecognizeTextRequest()
        let accurate = args[3] == "accurate"
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        request.usesCPUOnly = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations: [[String: Any]] = (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first, !text.string.isEmpty else { return nil }
                let box = observation.boundingBox
                return ["text": text.string, "x": box.minX * w, "y": (1 - box.maxY) * h,
                        "w": box.width * w, "h": box.height * h, "conf": text.confidence]
            }
            let data = try JSONSerialization.data(withJSONObject: observations)
            FileHandle.standardOutput.write(data)
            exit(0)
        } catch { exit(1) }
    }
}
