// Experimental offline worker; never used by Wand's runtime.
// swiftc examples/ocr/variants.swift -o /tmp/wand-ocr-variants
// WAND_OCR_VARIANT=scale2 python3 examples/ocr/evaluate.py /tmp/wand-ocr-variants CORPUS
import Foundation
import Vision
import ImageIO
import CoreImage

let args = CommandLine.arguments
let variant = ProcessInfo.processInfo.environment["WAND_OCR_VARIANT"] ?? "baseline"
guard args.count == 6, args[1] == "__ocr", args[5] == "fast",
      ["baseline", "scale2", "scale2nearest", "scale3", "invert", "language"].contains(variant),
      let width = Double(args[3]), let height = Double(args[4]),
      width.isFinite, height.isFinite, width > 0, height > 0,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
      var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(64) }

// Cap experimental scaling to small images; do not triple large tablet captures.
if variant.hasPrefix("scale"), max(image.width, image.height) < 600 {
    let factor = variant == "scale3" ? 3 : 2
    guard let context = CGContext(data: nil, width: image.width * factor, height: image.height * factor,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.interpolationQuality = variant == "scale2nearest" ? .none : .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    guard let scaled = context.makeImage() else { exit(1) }
    image = scaled
}
if variant == "invert" {
    let ci = CIImage(cgImage: image).applyingFilter("CIColorInvert")
    guard let inverted = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(ci, from: ci.extent)
    else { exit(1) }
    image = inverted
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast
request.usesLanguageCorrection = variant == "language"
request.usesCPUOnly = true
try VNImageRequestHandler(cgImage: image).perform([request])
let observations: [[String: Any]] = (request.results ?? []).compactMap { observation in
    guard let text = observation.topCandidates(1).first else { return nil }
    let box = observation.boundingBox
    return ["text": text.string, "conf": text.confidence,
            "x": box.minX * width, "y": (1 - box.maxY) * height,
            "w": box.width * width, "h": box.height * height]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys]))
