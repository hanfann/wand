import Foundation

/// Validate before dispatch (and before the first step of a batch). In
/// particular, never convert NaN/infinity to Int or silently turn typos into 0.
public enum CommandValidation {
    public static func validate(_ argv: [String]) throws {
        guard let command = argv.first else { throw invalid("missing command") }
        let a = Array(argv.dropFirst())
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw invalid("\(command): \(message)") }
        }
        func number(_ index: Int, range: ClosedRange<Double> = -1_000_000...1_000_000,
                    integer: Bool = false) throws {
            guard index < a.count, let value = Double(a[index]), value.isFinite,
                  range.contains(value), !integer || value.rounded() == value else {
                throw invalid("\(command): invalid numeric argument \(index + 1)")
            }
        }
        func selector(_ index: Int = 0) throws {
            try require(index < a.count && !a[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && a[index] != "#", "needs a nonempty selector")
        }
        func hidText(_ text: String) throws {
            try require(text.unicodeScalars.allSatisfy { (32...126).contains($0.value) || [9, 10, 13].contains($0.value) },
                        "HID typing supports US ASCII; use setvalue for Unicode")
        }
        switch command {
        case "tap":
            try selector()
            if a.count >= 2 && Double(a[0]) != nil {
                try require(a.count == 2, "expected x y")
                try number(0); try number(1)
            }
        case "tapocr", "find", "clear", "scrollto", "scrollTo": try selector()
        case "typein", "setvalue":
            try selector(); try require(a.count >= 2, "needs selector and text")
            if command == "typein" { try hidText(a.dropFirst().joined(separator: " ")) }
        case "type":
            try require(!a.isEmpty, "needs text"); try hidText(a.joined(separator: " "))
        case "key":
            try require(a.count == 1, "expected HID usage")
            try number(0, range: 0...65535, integer: true)
        case "swipe", "drag", "dragdrop":
            if command != "swipe" && a.count == 2 {
                try selector(); try selector(1)
            } else {
                try require(a.count == 4, "expected x1 y1 x2 y2")
                for i in 0..<4 { try number(i) }
            }
        case "longpress", "pinch", "rotate":
            try selector()
            let coordinates = a.count >= 2 && Double(a[0]) != nil
            let parameter = coordinates ? 2 : 1
            if coordinates { try number(0); try number(1) }
            if command == "longpress" {
                try require(a.count == parameter || a.count == parameter + 1, "unexpected arguments")
                if a.count > parameter { try number(parameter, range: 0...60) }
            } else {
                try require(a.count == parameter + 1, "needs scale/radians")
                try number(parameter, range: command == "pinch" ? 0.01...100 : -100...100)
            }
        case "crown", "scroll":
            try selector(); try require(a.count <= 2, "unexpected arguments")
            let direction = a[0].lowercased()
            if direction == "up" || direction == "down" {
                if a.count > 1 { try number(1, range: 1...100, integer: true) }
            } else {
                try require(command == "crown", "expected up or down")
                try number(0)
                if a.count > 1 { try number(1, range: 1...1000, integer: true) }
            }
        case "wait":
            try selector(); try require(a.count <= 2, "unexpected arguments")
            if a.count > 1 { try number(1, range: 0...60_000) }
        case "assert":
            try selector(); try require(a.count <= 2, "unexpected arguments")
            if a.count == 2 {
                try require(a[1] == "exists" || a[1] == "gone" || a[1].hasPrefix("value=") || a[1].hasPrefix("label="), "unknown assertion condition")
            }
        case "install", "launch", "terminate", "open": try selector()
        case "record": try require(a.first == "start" || a.first == "stop", "expected start or stop")
        case "permission": try require(a.count == 3, "expected action service bundle")
        default: break
        }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "wand.command", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
