#!/usr/bin/env swift
// mac_vision.swift
// Zero-dependency on-device computer vision CLI using Apple Vision & CoreImage (macOS 26+):
// foreground cutout (alpha PNG), document perspective crop, barcode/QR decoding, and image inspection.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

struct CutoutReport: Codable {
    let inputFile: String
    let outputPath: String
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let instanceCount: Int
    let cropped: Bool
}

struct DocCropReport: Codable {
    let inputFile: String
    let outputPath: String
    let confidence: Float
    let normalizedLighting: Bool
    let outputWidth: Int
    let outputHeight: Int
}

struct BarcodeEntry: Codable {
    let payload: String
    let symbology: String
    let confidence: Float
    let isGS1DataCarrier: Bool
    let boxTopLeftNormalized: [Double] // [ymin, xmin, ymax, xmax]
}

struct BarcodesReport: Codable {
    let inputFile: String
    let width: Int
    let height: Int
    let count: Int
    let barcodes: [BarcodeEntry]
}

struct ClassificationEntry: Codable {
    let label: String
    let confidence: Float
}

struct InspectReport: Codable {
    let inputFile: String
    let width: Int
    let height: Int
    let overallAestheticsScore: Float
    let isUtilityImage: Bool
    let faceCount: Int
    let textRegionCount: Int
    let topClassifications: [ClassificationEntry]
}

func printUsage() {
    let usage = """
    Usage:
      mac-vision <subcommand> <image_path> [options]

    Subcommands:
      cutout <image> --out <out.png> [--crop]
          Remove background and export an RGBA PNG with transparent alpha channel.

      doc-crop <image> --out <out.png> [--normalize-lighting]
          Detect document boundaries and apply perspective rectification.

      barcodes <image> [--format json|md] [--out <path>]
          Decode QR codes, DataMatrix, EAN/UPC, Code128, PDF417, and other barcodes.

      inspect <image> [--top 8] [--format json|md] [--out <path>]
          Inspect image dimensions, aesthetics score, utility flag, faces, text regions, and labels.
    """
    fputs(usage + "\n", stderr)
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

func writeTextOutput(_ content: String, to outPath: String?) throws {
    if let outPath {
        let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        fputs("Wrote output to \(url.path)\n", stderr)
    } else {
        print(content)
    }
}

func loadOrientedImage(path: String) throws -> (url: URL, ciImage: CIImage, cgImage: CGImage) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw NSError(domain: "MacVision", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(url.path)"])
    }
    guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to decode image: \(url.path)"])
    }
    let context = CIContext(options: nil)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        throw NSError(domain: "MacVision", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize image: \(url.path)"])
    }
    return (url, ciImage, cgImage)
}

func writeRGBAPNG(ciImage: CIImage, to outPath: String) throws -> (url: URL, width: Int, height: Int) {
    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = CIContext(options: nil)
    // Shift origin to (0, 0) so PNG dimensions match the cropped extent cleanly.
    let extent = ciImage.extent
    let normalized = ciImage.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
    try context.writePNGRepresentation(of: normalized, to: outURL, format: .RGBA8, colorSpace: colorSpace, options: [:])
    return (outURL, Int(extent.width.rounded()), Int(extent.height.rounded()))
}

func runCutout(args: [String]) throws {
    var inputPath: String?
    var outPath: String?
    var crop = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a PNG path"]) }
            outPath = args[i]
        case "--crop":
            crop = true
        default:
            if args[i].hasPrefix("-") {
                throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(args[i])"])
            }
            inputPath = args[i]
        }
        i += 1
    }

    guard let inPath = inputPath, let outPath else {
        throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: mac-vision cutout <image> --out <out.png> [--crop]"])
    }

    let (inURL, _, cgImage) = try loadOrientedImage(path: inPath)
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
        throw NSError(domain: "MacVision", code: 4, userInfo: [NSLocalizedDescriptionKey: "No foreground subject detected in \(inURL.lastPathComponent)"])
    }

    let pixelBuffer = try obs.generateMaskedImage(
        ofInstances: obs.allInstances,
        from: handler,
        croppedToInstancesExtent: crop
    )
    let maskedCI = CIImage(cvPixelBuffer: pixelBuffer)
    let (outURL, outW, outH) = try writeRGBAPNG(ciImage: maskedCI, to: outPath)

    let report = CutoutReport(
        inputFile: inURL.lastPathComponent,
        outputPath: outURL.path,
        inputWidth: cgImage.width,
        inputHeight: cgImage.height,
        outputWidth: outW,
        outputHeight: outH,
        instanceCount: obs.allInstances.count,
        cropped: crop
    )
    print(try encodeJSON(report))
}

@available(macOS 26.0, *)
func runDocCrop(args: [String]) async throws {
    var inputPath: String?
    var outPath: String?
    var normalizeLighting = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a PNG path"]) }
            outPath = args[i]
        case "--normalize-lighting":
            normalizeLighting = true
        default:
            if args[i].hasPrefix("-") {
                throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(args[i])"])
            }
            inputPath = args[i]
        }
        i += 1
    }

    guard let inPath = inputPath, let outPath else {
        throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: mac-vision doc-crop <image> --out <out.png> [--normalize-lighting]"])
    }

    let (inURL, ciImage, cgImage) = try loadOrientedImage(path: inPath)
    let request = DetectDocumentSegmentationRequest()
    guard let obs = try await request.perform(on: cgImage), obs.confidence >= 0.2 else {
        throw NSError(domain: "MacVision", code: 5, userInfo: [NSLocalizedDescriptionKey: "No document boundary confidently detected in \(inURL.lastPathComponent)"])
    }

    let size = ciImage.extent.size
    let origin = ciImage.extent.origin
    func toCI(_ p: NormalizedPoint) -> CIVector {
        let pt = p.toImageCoordinates(size, origin: .lowerLeft)
        return CIVector(x: pt.x + origin.x, y: pt.y + origin.y)
    }

    guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
        throw NSError(domain: "MacVision", code: 6, userInfo: [NSLocalizedDescriptionKey: "CIPerspectiveCorrection filter unavailable"])
    }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(toCI(obs.topLeft), forKey: "inputTopLeft")
    filter.setValue(toCI(obs.topRight), forKey: "inputTopRight")
    filter.setValue(toCI(obs.bottomLeft), forKey: "inputBottomLeft")
    filter.setValue(toCI(obs.bottomRight), forKey: "inputBottomRight")

    guard var outputCI = filter.outputImage else {
        throw NSError(domain: "MacVision", code: 7, userInfo: [NSLocalizedDescriptionKey: "Perspective correction produced no output"])
    }

    if normalizeLighting {
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(outputCI, forKey: kCIInputImageKey)
            hs.setValue(0.75, forKey: "inputShadowAmount")
            hs.setValue(1.0, forKey: "inputHighlightAmount")
            if let enhanced = hs.outputImage { outputCI = enhanced }
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(outputCI, forKey: kCIInputImageKey)
            cc.setValue(1.12, forKey: kCIInputContrastKey)
            cc.setValue(0.03, forKey: kCIInputBrightnessKey)
            if let adjusted = cc.outputImage { outputCI = adjusted }
        }
    }

    let (outURL, outW, outH) = try writeRGBAPNG(ciImage: outputCI, to: outPath)
    let report = DocCropReport(
        inputFile: inURL.lastPathComponent,
        outputPath: outURL.path,
        confidence: obs.confidence,
        normalizedLighting: normalizeLighting,
        outputWidth: outW,
        outputHeight: outH
    )
    print(try encodeJSON(report))
}

@available(macOS 26.0, *)
func runBarcodes(args: [String]) async throws {
    var inputPath: String?
    var format = "json"
    var outPath: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or md"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if args[i].hasPrefix("-") {
                throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(args[i])"])
            }
            inputPath = args[i]
        }
        i += 1
    }

    guard let inPath = inputPath else {
        throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: mac-vision barcodes <image> [--format json|md]"])
    }

    let (inURL, _, cgImage) = try loadOrientedImage(path: inPath)
    let request = DetectBarcodesRequest()
    let observations = try await request.perform(on: cgImage)

    let entries: [BarcodeEntry] = observations.map { obs in
        let xs = [obs.topLeft.x, obs.topRight.x, obs.bottomLeft.x, obs.bottomRight.x]
        let ys = [obs.topLeft.y, obs.topRight.y, obs.bottomLeft.y, obs.bottomRight.y]
        let xmin = max(0.0, min(1.0, Double(xs.min() ?? 0)))
        let xmax = max(0.0, min(1.0, Double(xs.max() ?? 0)))
        let ymin = max(0.0, min(1.0, Double(1.0 - (ys.max() ?? 0))))
        let ymax = max(0.0, min(1.0, Double(1.0 - (ys.min() ?? 0))))
        return BarcodeEntry(
            payload: obs.payloadString ?? "",
            symbology: String(describing: obs.symbology),
            confidence: obs.confidence,
            isGS1DataCarrier: obs.isGS1DataCarrier,
            boxTopLeftNormalized: [ymin, xmin, ymax, xmax]
        )
    }

    let report = BarcodesReport(
        inputFile: inURL.lastPathComponent,
        width: cgImage.width,
        height: cgImage.height,
        count: entries.count,
        barcodes: entries
    )

    if format == "md" {
        var md = ["# Barcodes: \(report.inputFile) (\(report.count) found)"]
        for (idx, b) in entries.enumerated() {
            md.append("- [\(idx + 1)] `\(b.symbology)` (`\(String(format: "%.2f", b.confidence))`): `\(b.payload)`")
        }
        try writeTextOutput(md.joined(separator: "\n"), to: outPath)
    } else {
        try writeTextOutput(try encodeJSON(report), to: outPath)
    }
}

@available(macOS 26.0, *)
func runInspect(args: [String]) async throws {
    var inputPath: String?
    var topK = 8
    var format = "json"
    var outPath: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--top":
            i += 1
            guard i < args.count, let val = Int(args[i]), val >= 1 else {
                throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--top requires a positive integer"])
            }
            topK = val
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or md"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if args[i].hasPrefix("-") {
                throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(args[i])"])
            }
            inputPath = args[i]
        }
        i += 1
    }

    guard let inPath = inputPath else {
        throw NSError(domain: "MacVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: mac-vision inspect <image> [--top 8] [--format json|md]"])
    }

    let (inURL, _, cgImage) = try loadOrientedImage(path: inPath)

    async let clsTask = ClassifyImageRequest().perform(on: cgImage)
    async let aesTask = CalculateImageAestheticsScoresRequest().perform(on: cgImage)
    async let faceTask = DetectFaceRectanglesRequest().perform(on: cgImage)
    async let textTask = DetectTextRectanglesRequest().perform(on: cgImage)

    let (clsObs, aesObs, faceObs, textObs) = try await (clsTask, aesTask, faceTask, textTask)

    let topLabels = clsObs
        .filter { $0.confidence >= 0.05 }
        .sorted { $0.confidence > $1.confidence }
        .prefix(topK)
        .map { ClassificationEntry(label: $0.identifier, confidence: $0.confidence) }

    let report = InspectReport(
        inputFile: inURL.lastPathComponent,
        width: cgImage.width,
        height: cgImage.height,
        overallAestheticsScore: aesObs.overallScore,
        isUtilityImage: aesObs.isUtility,
        faceCount: faceObs.count,
        textRegionCount: textObs.count,
        topClassifications: topLabels
    )

    if format == "md" {
        var md = ["# Image Inspection: \(report.inputFile)"]
        md.append("- Dimensions: \(report.width) x \(report.height) px")
        md.append(String(format: "- Aesthetics Score: %.3f | Utility Image: %@", report.overallAestheticsScore, report.isUtilityImage ? "true" : "false"))
        md.append("- Faces: \(report.faceCount) | Text Regions: \(report.textRegionCount)")
        if !topLabels.isEmpty {
            let formatted = topLabels.map { String(format: "%@ (%.0f%%)", $0.label, $0.confidence * 100) }.joined(separator: ", ")
            md.append("- Top Labels: \(formatted)")
        }
        try writeTextOutput(md.joined(separator: "\n"), to: outPath)
    } else {
        try writeTextOutput(try encodeJSON(report), to: outPath)
    }
}

func runMain() async {
    guard #available(macOS 26.0, *) else {
        fputs("Error: macOS 26.0 or later is required\n", stderr)
        exit(1)
    }

    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args[0] == "--help" || args[0] == "-h" {
        printUsage()
        exit(args.isEmpty ? 1 : 0)
    }

    let sub = args[0]
    let rest = Array(args.dropFirst())

    do {
        switch sub {
        case "cutout":
            try runCutout(args: rest)
        case "doc-crop":
            try await runDocCrop(args: rest)
        case "barcodes":
            try await runBarcodes(args: rest)
        case "inspect":
            try await runInspect(args: rest)
        default:
            fputs("Error: Unknown subcommand '\(sub)'\n", stderr)
            printUsage()
            exit(1)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

Task {
    await runMain()
    exit(0)
}
RunLoop.main.run()
