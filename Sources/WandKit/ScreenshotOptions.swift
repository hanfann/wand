import Foundation

public struct ScreenshotOptions {
    public struct Crop: Equatable {
        public let x: Int, y: Int, width: Int, height: Int
    }
    public let path: String?
    public let maxEdge: Int?
    public let crop: Crop?

    public init(arguments: [String]) throws {
        var path: String?, edge: Int?, crop: Crop?
        var index = 0
        func integer(_ offset: Int, minimum: Int, maximum: Int) throws -> Int {
            guard offset < arguments.count, let value = Int(arguments[offset]),
                  (minimum...maximum).contains(value) else { throw Self.invalid() }
            return value
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--preview":
                guard edge == nil else { throw Self.invalid() }
                edge = try integer(index + 1, minimum: 1, maximum: 4096)
                index += 2
            case "--crop":
                guard crop == nil else { throw Self.invalid() }
                crop = try Crop(x: integer(index + 1, minimum: 0, maximum: 1_000_000),
                                y: integer(index + 2, minimum: 0, maximum: 1_000_000),
                                width: integer(index + 3, minimum: 1, maximum: 1_000_000),
                                height: integer(index + 4, minimum: 1, maximum: 1_000_000))
                index += 5
            default:
                guard path == nil, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else { throw Self.invalid() }
                path = arguments[index]
                index += 1
            }
        }
        guard crop == nil || edge != nil else { throw Self.invalid() }
        self.path = path
        self.maxEdge = edge
        self.crop = crop
    }

    private static func invalid() -> NSError {
        NSError(domain: "wand.screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "screenshot [path] [--preview 1...4096] [--crop x y width height]; crop uses nonnegative source pixels and requires preview"])
    }
}
