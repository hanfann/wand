// Deterministic raster corpus with known text and bounds. Optional local pixel font.
// swift examples/ocr/corpus.swift OUTPUT_DIR [FONT_TTF]
import AppKit
import CoreText
import Foundation
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
var fonts: [(String, NSFont)] = [("system", .systemFont(ofSize: 30)), ("small", .systemFont(ofSize: 20)), ("mono", .monospacedSystemFont(ofSize: 26, weight: .regular))]
if CommandLine.arguments.count > 2 {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    if let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider), let name = font.postScriptName,
       let loaded = NSFont(name: name as String, size: 30) { fonts.append(("pixel", loaded)) }
}
let groups = [["Friend streak", "70 days", "Wear it", "Not now"], ["Notifications", "General", "Display", "Settings"]]
var corpus: [[String: Any]] = []
for (fontName, font) in fonts {
    for (index, labels) in groups.enumerated() {
        let dark = index == 0
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 324, pixelsHigh: 394,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor.black : NSColor.white).setFill(); NSRect(x: 0, y: 0, width: 324, height: 394).fill()
        var targets: [[String: Any]] = []
        for (row, label) in labels.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black]
            let size = (label as NSString).size(withAttributes: attrs)
            let x = 20.0, y = 330.0 - Double(row * 80)
            (label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            targets.append(["text": label, "x": x, "y": 394 - y - size.height, "w": size.width, "h": size.height])
        }
        NSGraphicsContext.restoreGraphicsState()
        let file = "\(fontName)-\(index).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination + "/" + file))
        corpus.append(["file": file, "font": fontName, "width": 324, "height": 394, "targets": targets])
    }
}
try JSONSerialization.data(withJSONObject: corpus, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: destination + "/manifest.json"))
print("Generated \(corpus.count) screens / \(corpus.count * 4) labelled targets")
