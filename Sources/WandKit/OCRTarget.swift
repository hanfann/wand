import Foundation

/// Resolve recognized text without guessing between duplicate labels or unsafe geometry.
public enum OCRTarget {
    public enum Failure: String, LocalizedError {
        case empty = "OCR target must not be empty"
        case ambiguous = "ambiguous OCR target; use screenshot coordinates"
        case uncertain = "uncertain or off-screen OCR target; use screenshot coordinates"
        public var errorDescription: String? { rawValue }
    }
    public struct Match {
        public let x: Double, y: Double
        public let text: String
    }
    public static func resolve(_ query: String, observations: [[String: Any]],
                               width: Double, height: Double, exactOnly: Bool = false, minConfidence: Double = 0.6) throws -> Match? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { throw Failure.empty }
        let exact = observations.filter { ($0["text"] as? String)?.lowercased() == needle }
        let matches = exact.isEmpty && !exactOnly ? observations.filter {
            ($0["text"] as? String)?.lowercased().contains(needle) == true
        } : exact
        guard matches.count <= 1 else { throw Failure.ambiguous }
        guard let hit = matches.first else { return nil }
        guard let x = hit["x"] as? Double, let y = hit["y"] as? Double,
              let w = hit["w"] as? Double, let h = hit["h"] as? Double,
              let confidence = hit["conf"] as? Double,
              [x, y, w, h, width, height, confidence].allSatisfy({ $0.isFinite }),
              w > 0, h > 0, confidence >= minConfidence, x >= 0, y >= 0,
              x + w <= width + 0.5, y + h <= height + 0.5,
              let text = hit["text"] as? String else {
            throw Failure.uncertain
        }
        return Match(x: x + w / 2, y: y + h / 2, text: text)
    }
}
