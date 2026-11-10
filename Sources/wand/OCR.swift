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
    struct Frame {
        fileprivate let path: String
        fileprivate let key: String
        let width: Double
        let height: Double
    }

    enum Failure: String, LocalizedError {
        case timedOut = "OCR timed out; input daemon remains usable. Use screenshot and point coordinates"
        case cancelled = "OCR cancelled; no input was sent"
        case coolingDown = "Automatic accurate OCR is cooling down for up to 60s after a timeout. Use screenshot coordinates or explicitly retry with see accurate"
        case workerFailed = "OCR failed; use screenshot and point coordinates"
        var errorDescription: String? { rawValue }
    }

    var cancelled: (() -> Bool)?
    private let workerExecutable: String
    private let temporaryDirectory: String
    private let now: () -> TimeInterval
    private var accurateUnavailableUntil: TimeInterval = 0
    private var cachedKey: String?
    // At most one image, with independent results for its two recognition modes.
    private var cached: [Bool: [[String: Any]]] = [:]

    init(workerExecutable: String = Client.executablePath(),
         temporaryDirectory: String = Net.socketDir(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.workerExecutable = workerExecutable
        self.temporaryDirectory = temporaryDirectory
        self.now = now
    }

    func recognize(sim: WNDSimulator, accurate: Bool = false) throws -> [[String: Any]] {
        try withFrame(sim: sim) { try recognize(frame: $0, accurate: accurate) }
    }

    func withFrame<T>(sim: WNDSimulator, body: (Frame) throws -> T) throws -> T {
        try withFrame(width: Double(sim.screenPointSize.width), height: Double(sim.screenPointSize.height),
                      capture: { try sim.screenshot(toPath: $0) }, body: body)
    }

    // A frame only lives for this operation, including both fallback attempts.
    // Every later operation captures again before consulting the exact-image cache.
    func withFrame<T>(width: Double, height: Double, capture: (String) throws -> Void,
                      body: (Frame) throws -> T) throws -> T {
        try checkCancellation()
        let path = temporaryDirectory + "/ocr-" + UUID().uuidString + ".png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        try capture(path)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            + "|\(width)|\(height)"
        return try body(Frame(path: path, key: key, width: width, height: height))
    }

    func recognize(frame: Frame, accurate: Bool = false, automatic: Bool = false) throws -> [[String: Any]] {
        try checkCancellation()
        if frame.key != cachedKey {
            cachedKey = frame.key
            cached.removeAll(keepingCapacity: true)
        }
        if let observations = cached[accurate] { return observations }
        if accurate && automatic && now() < accurateUnavailableUntil { throw Failure.coolingDown }

        let resultPath = temporaryDirectory + "/ocr-" + UUID().uuidString + ".json"
        defer { try? FileManager.default.removeItem(atPath: resultPath) }
        FileManager.default.createFile(atPath: resultPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let result = try FileHandle(forWritingTo: URL(fileURLWithPath: resultPath))
        defer { try? result.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: workerExecutable)
        process.arguments = ["__ocr", frame.path, String(frame.width),
                             String(frame.height), accurate ? "accurate" : "fast"]
        process.standardOutput = result
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + (accurate ? 5 : 3)
        while process.isRunning && cancelled?() != true && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        if process.isRunning {
            let wasCancelled = cancelled?() == true
            process.terminate()
            usleep(50_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            if wasCancelled { throw Failure.cancelled }
            if accurate { accurateUnavailableUntil = now() + 60 }
            throw Failure.timedOut
        }
        try checkCancellation()
        let data = try Data(contentsOf: URL(fileURLWithPath: resultPath))
        guard process.terminationStatus == 0,
              let observations = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw Failure.workerFailed
        }
        if accurate { accurateUnavailableUntil = 0 }
        cached[accurate] = observations
        return observations
    }

    private func checkCancellation() throws {
        if cancelled?() == true { throw Failure.cancelled }
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
