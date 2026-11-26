#!/usr/bin/env swift
// mac_ocr.swift
// Zero-dependency on-device PDF & image OCR CLI using PDFKit, Vision.RecognizeDocumentsRequest,
// and optional FoundationModels triage (macOS 26+).

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Vision

enum OutputFormat: String {
    case markdown
    case md
    case json

    var isJson: Bool { self == .json }
}

enum OCRMode: String {
    case auto
    case vision
    case pdfText = "pdf-text"
}

struct Options {
    let inputPath: String
    var pageRangeSpec: String?
    var dpi: CGFloat = 200.0
    var format: OutputFormat = .markdown
    var ocrMode: OCRMode = .auto
    var languages: [String] = ["en-US", "ja-JP"]
    var useLanguageCorrection: Bool = true
    var useOnDeviceClassify: Bool = false
    var classifyPrompt: String?
    var concurrency: Int = 4
    var contactSheetPath: String?
    var outputPath: String?
}

struct PageOCRResult: Codable, Sendable {
    let page: Int
    let widthPx: Int
    let heightPx: Int
    let extractionSource: String
    let charCount: Int
    let tableCount: Int
    let listCount: Int
    let suggestedKind: String
    let titleHint: String
    let summary: String
    let transcript: String
    let paragraphs: [String]
    let tables: [[[String]]]
}

struct DocumentOCRReport: Codable {
    let inputFile: String
    let apiUsed: String
    let ocrMode: String
    let languages: [String]
    let onDeviceClassify: Bool
    let totalPages: Int
    let processedPages: Int
    let dpi: Int
    let languageCorrection: Bool
    let pages: [PageOCRResult]
}

@available(macOS 26.0, *)
@Generable
struct OnDevicePageTriage {
    @Guide(description: "Page classification: content, toc_or_index, cover_or_blank, front_or_back_matter, or appendix_or_reference")
    var kind: String
    @Guide(description: "Concise section heading or title if present, otherwise empty string")
    var titleHint: String
    @Guide(description: "One short sentence summarizing the main topic of this page, or empty if blank")
    var summary: String
}

func printUsage() {
    let usage = """
    Usage:
      mac-ocr <input.pdf|image> [options]

    Options:
      --pages <1-3,5>              Target 1-based page ranges for PDF (default: all)
      --dpi <200>                  PDF rendering DPI between 72 and 600 (default: 200)
      --format <md|json>           Output format: markdown (md) or json (default: md)
      --ocr-mode <mode>            auto (default), vision (force OCR), or pdf-text (embedded text only)
      --langs <en-US,ja-JP>        Comma-separated BCP-47 language codes (default: en-US,ja-JP)
      --no-lang-correction         Disable Vision language correction (recommended for code, IDs, or math)
      --concurrency <4>            Max parallel Vision OCR tasks, 1-8 (default: 4)
      --classify                   Run on-device FoundationModels page triage (kind, titleHint, summary)
      --classify-prompt <text>     Custom instructions for on-device page classification
      --contact-sheet <path.png>   Generate a labeled 4-column PNG contact sheet for PDF screening
      --out <path>                 Write output to file instead of stdout
      --help, -h                   Show this help message
    """
    fputs(usage + "\n", stderr)
}

func parseArgs() -> Options? {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") || args.contains("-h") {
        printUsage()
        return nil
    }

    var opts = Options(inputPath: "")
    var inputPath: String?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--pages":
            i += 1
            guard i < args.count else { fputs("Error: --pages requires a value\n", stderr); return nil }
            opts.pageRangeSpec = args[i]
        case "--dpi":
            i += 1
            guard i < args.count, let val = Double(args[i]), val >= 72, val <= 600 else {
                fputs("Error: --dpi requires a number between 72 and 600\n", stderr)
                return nil
            }
            opts.dpi = CGFloat(val)
        case "--format":
            i += 1
            guard i < args.count, let fmt = OutputFormat(rawValue: args[i].lowercased()) else {
                fputs("Error: --format must be 'markdown', 'md', or 'json'\n", stderr)
                return nil
            }
            opts.format = fmt
        case "--ocr-mode":
            i += 1
            guard i < args.count, let mode = OCRMode(rawValue: args[i].lowercased()) else {
                fputs("Error: --ocr-mode must be 'auto', 'vision', or 'pdf-text'\n", stderr)
                return nil
            }
            opts.ocrMode = mode
        case "--langs":
            i += 1
            guard i < args.count else { fputs("Error: --langs requires a comma-separated list\n", stderr); return nil }
            let parsed = args[i]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parsed.isEmpty else { fputs("Error: --langs cannot be empty\n", stderr); return nil }
            opts.languages = parsed
        case "--no-lang-correction":
            opts.useLanguageCorrection = false
        case "--concurrency":
            i += 1
            guard i < args.count, let val = Int(args[i]), val >= 1, val <= 8 else {
                fputs("Error: --concurrency requires an integer between 1 and 8\n", stderr)
                return nil
            }
            opts.concurrency = val
        case "--classify":
            opts.useOnDeviceClassify = true
        case "--classify-prompt":
            i += 1
            guard i < args.count else { fputs("Error: --classify-prompt requires text\n", stderr); return nil }
            opts.classifyPrompt = args[i]
        case "--contact-sheet":
            i += 1
            guard i < args.count else { fputs("Error: --contact-sheet requires a file path\n", stderr); return nil }
            opts.contactSheetPath = args[i]
        case "--out":
            i += 1
            guard i < args.count else { fputs("Error: --out requires a file path\n", stderr); return nil }
            opts.outputPath = args[i]
        default:
            if arg.hasPrefix("-") {
                fputs("Error: Unknown option \(arg)\n", stderr)
                return nil
            }
            if inputPath == nil {
                inputPath = arg
            } else {
                fputs("Error: Multiple input paths provided: \(arg)\n", stderr)
                return nil
            }
        }
        i += 1
    }

    guard let path = inputPath else {
        fputs("Error: Input file path is required\n", stderr)
        printUsage()
        return nil
    }

    return Options(
        inputPath: path,
        pageRangeSpec: opts.pageRangeSpec,
        dpi: opts.dpi,
        format: opts.format,
        ocrMode: opts.ocrMode,
        languages: opts.languages,
        useLanguageCorrection: opts.useLanguageCorrection,
        useOnDeviceClassify: opts.useOnDeviceClassify,
        classifyPrompt: opts.classifyPrompt,
        concurrency: opts.concurrency,
        contactSheetPath: opts.contactSheetPath,
        outputPath: opts.outputPath
    )
}

func parsePageSpec(_ spec: String?, totalPages: Int) -> [Int]? {
    guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else {
        return Array(1...totalPages)
    }
    var pages = Set<Int>()
    for part in spec.split(separator: ",") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("-") {
            let bounds = trimmed.split(separator: "-", maxSplits: 1).map { String($0) }
            guard bounds.count == 2,
                  let start = Int(bounds[0]),
                  let end = Int(bounds[1]),
                  start >= 1, end >= start
            else {
                fputs("Error: Invalid page range '\(trimmed)'\n", stderr)
                return nil
            }
            for p in start...min(end, totalPages) {
                pages.insert(p)
            }
        } else if let p = Int(trimmed), p >= 1 {
            if p <= totalPages {
                pages.insert(p)
            }
        } else {
            fputs("Error: Invalid page number '\(trimmed)'\n", stderr)
            return nil
        }
    }
    return pages.sorted()
}

func renderPDFPage(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let width = max(1, Int((bounds.width * scale).rounded()))
    let height = max(1, Int((bounds.height * scale).rounded()))

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()

    return context.makeImage()
}

func loadOrientedCGImage(url: URL) -> CGImage? {
    if let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
        let context = CIContext(options: nil)
        if let rendered = context.createCGImage(ciImage, from: ciImage.extent) {
            return rendered
        }
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func isUsableEmbeddedPDFText(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let compact = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    guard compact.count >= 40 else { return nil }
    let replacementCount = compact.filter { $0 == "\u{FFFD}" }.count
    if Double(replacementCount) / Double(compact.count) > 0.02 {
        return nil
    }
    return trimmed
}

func classifyPageRuleBased(transcript: String) -> String {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count < 25 {
        return "cover_or_blank"
    }
    let lowered = trimmed.lowercased()
    let tocHints = ["table of contents", "contents", "index", "目次", "もくじ", "索引"]
    let matterHints = [
        "copyright", "all rights reserved", "isbn", "printed in", "preface", "foreword",
        "acknowledgments", "acknowledgements", "colophon", "奥付", "発行所", "定価",
        "まえがき", "はじめに", "おわりに"
    ]
    if tocHints.contains(where: { lowered.contains($0) }) && trimmed.count < 1400 {
        return "toc_or_index"
    }
    if matterHints.contains(where: { lowered.contains($0) }) && trimmed.count < 1000 {
        return "front_or_back_matter"
    }
    return "content"
}

@available(macOS 26.0, *)
func classifyWithFoundationModels(transcript: String, customPrompt: String?) async -> OnDevicePageTriage? {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count < 15 {
        return OnDevicePageTriage(kind: "cover_or_blank", titleHint: "", summary: "")
    }
    guard case .available = SystemLanguageModel.default.availability else {
        return nil
    }
    let snippet = String(trimmed.prefix(1500))
    let defaultInstructions = """
    You are a document page triage classifier. Classify the OCR text into one of:
    content, toc_or_index, cover_or_blank, front_or_back_matter, or appendix_or_reference.
    Extract a concise titleHint if visible and write a single-sentence summary.
    """
    let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    let session = LanguageModelSession(model: model, instructions: customPrompt ?? defaultInstructions)
    do {
        let response = try await session.respond(to: snippet, generating: OnDevicePageTriage.self)
        return response.content
    } catch {
        return nil
    }
}

@available(macOS 26.0, *)
func recognizeWithDocumentsAPI(
    image: CGImage,
    pageNumber: Int,
    languages: [String],
    useLanguageCorrection: Bool
) async throws -> PageOCRResult {
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
    request.textRecognitionOptions.useLanguageCorrection = useLanguageCorrection

    let observations = try await request.perform(on: image)
    guard let doc = observations.first?.document else {
        return PageOCRResult(
            page: pageNumber,
            widthPx: image.width,
            heightPx: image.height,
            extractionSource: "vision_documents",
            charCount: 0,
            tableCount: 0,
            listCount: 0,
            suggestedKind: "cover_or_blank",
            titleHint: "",
            summary: "",
            transcript: "",
            paragraphs: [],
            tables: []
        )
    }

    let transcript = doc.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let paragraphs = doc.paragraphs
        .map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let tables: [[[String]]] = doc.tables.map { table in
        table.rows.map { row in
            row.map { cell in
                cell.content.text.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    return PageOCRResult(
        page: pageNumber,
        widthPx: image.width,
        heightPx: image.height,
        extractionSource: "vision_documents",
        charCount: transcript.count,
        tableCount: tables.count,
        listCount: doc.lists.count,
        suggestedKind: classifyPageRuleBased(transcript: transcript),
        titleHint: "",
        summary: "",
        transcript: transcript,
        paragraphs: paragraphs,
        tables: tables
    )
}

func generateContactSheet(
    pdf: PDFDocument,
    pageResults: [PageOCRResult],
    outputPath: String
) throws {
    let columns = 4
    let cellW: CGFloat = 320
    let cellH: CGFloat = 440
    let padding: CGFloat = 16
    let rows = max(1, (pageResults.count + columns - 1) / columns)

    let totalW = Int(CGFloat(columns) * cellW + CGFloat(columns + 1) * padding)
    let totalH = Int(CGFloat(rows) * cellH + CGFloat(rows + 1) * padding)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: totalW,
        height: totalH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "MacOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate contact sheet context"])
    }

    ctx.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    for (idx, res) in pageResults.enumerated() {
        let col = idx % columns
        let row = idx / columns
        let x = padding + CGFloat(col) * (cellW + padding)
        let y = CGFloat(totalH) - padding - CGFloat(row + 1) * cellH - CGFloat(row) * padding
        let cellRect = CGRect(x: x, y: y, width: cellW, height: cellH)

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(cellRect)

        autoreleasepool {
            if let page = pdf.page(at: res.page - 1), let thumb = renderPDFPage(page, dpi: 72) {
                let aspect = CGFloat(thumb.width) / max(1, CGFloat(thumb.height))
                let targetH = cellH - 34
                let targetW = min(cellW - 8, targetH * aspect)
                let drawH = targetW / max(0.1, aspect)
                let drawRect = CGRect(
                    x: x + (cellW - targetW) / 2,
                    y: y + 4 + (targetH - drawH) / 2,
                    width: targetW,
                    height: drawH
                )
                ctx.draw(thumb, in: drawRect)
            }
        }

        let isSkip = res.suggestedKind != "content" && res.suggestedKind != "appendix_or_reference"
        let borderColor = isSkip
            ? CGColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1)
            : CGColor(red: 0.78, green: 0.82, blue: 0.88, alpha: 1)
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(isSkip ? 3 : 1.5)
        ctx.stroke(cellRect)

        let badgeRect = CGRect(x: x, y: y + cellH - 28, width: cellW, height: 28)
        ctx.setFillColor(isSkip ? CGColor(red: 0.78, green: 0.22, blue: 0.22, alpha: 0.92) : CGColor(red: 0.14, green: 0.24, blue: 0.42, alpha: 0.92))
        ctx.fill(badgeRect)

        let label = "p.\(res.page) [\(res.suggestedKind)] \(res.charCount) chars"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        label.draw(at: NSPoint(x: x + 8, y: y + cellH - 22), withAttributes: attrs)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let outImage = ctx.makeImage() else {
        throw NSError(domain: "MacOCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to build contact sheet image"])
    }
    let outURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "MacOCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "MacOCR", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to write contact sheet PNG"])
    }
    fputs("Wrote contact sheet (\(pageResults.count) pages) to \(outURL.path)\n", stderr)
}

func formatMarkdown(_ report: DocumentOCRReport) -> String {
    var out: [String] = []
    out.append("# OCR Report: \(report.inputFile)")
    out.append("- API: `\(report.apiUsed)` (mode: `\(report.ocrMode)`, langs: `\(report.languages.joined(separator: ","))`, classify: \(report.onDeviceClassify))")
    out.append("- Pages: \(report.processedPages) / \(report.totalPages) (DPI: \(report.dpi), LanguageCorrection: \(report.languageCorrection))")
    out.append("")
    out.append("## Page Index")
    out.append("| Page | Source | Kind | Title Hint | Chars | Tables | Lists |")
    out.append("| ---: | :--- | :--- | :--- | ---: | ---: | ---: |")
    for p in report.pages {
        let hint = p.titleHint.isEmpty ? "-" : p.titleHint.replacingOccurrences(of: "|", with: "/")
        out.append("| \(p.page) | \(p.extractionSource) | \(p.suggestedKind) | \(hint) | \(p.charCount) | \(p.tableCount) | \(p.listCount) |")
    }
    out.append("")

    for p in report.pages {
        out.append("---")
        let hintSuffix = p.titleHint.isEmpty ? "" : " — \(p.titleHint)"
        out.append("## Page \(p.page) (`\(p.suggestedKind)`, \(p.extractionSource), \(p.charCount) chars\(hintSuffix))")
        if !p.summary.isEmpty {
            out.append("> Summary: \(p.summary)")
        }
        out.append("")
        if p.transcript.isEmpty {
            out.append("_(No text detected)_")
            out.append("")
        } else {
            out.append(p.transcript)
            out.append("")
        }
        if !p.tables.isEmpty {
            for (idx, table) in p.tables.enumerated() where !table.isEmpty {
                out.append("### Table \(idx + 1)")
                let colCount = table.map(\.count).max() ?? 0
                if colCount > 0 {
                    let header = table[0] + Array(repeating: "", count: max(0, colCount - table[0].count))
                    out.append("| " + header.joined(separator: " | ") + " |")
                    out.append("| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |")
                    for row in table.dropFirst() {
                        let padded = row + Array(repeating: "", count: max(0, colCount - row.count))
                        out.append("| " + padded.joined(separator: " | ") + " |")
                    }
                    out.append("")
                }
            }
        }
    }
    return out.joined(separator: "\n")
}

@available(macOS 26.0, *)
func processPDF(pdf: PDFDocument, targetPages: [Int], opts: Options) async throws -> [PageOCRResult] {
    var results: [PageOCRResult] = []
    var visionQueue: [(pageNum: Int, image: CGImage)] = []

    for pageNum in targetPages {
        guard let page = pdf.page(at: pageNum - 1) else { continue }
        if opts.ocrMode != .vision, let embedded = isUsableEmbeddedPDFText(page.string) {
            let bounds = page.bounds(for: .mediaBox)
            let paragraphs = embedded.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            results.append(PageOCRResult(
                page: pageNum,
                widthPx: Int(bounds.width),
                heightPx: Int(bounds.height),
                extractionSource: "pdf_text",
                charCount: embedded.count,
                tableCount: 0,
                listCount: 0,
                suggestedKind: classifyPageRuleBased(transcript: embedded),
                titleHint: "",
                summary: "",
                transcript: embedded,
                paragraphs: paragraphs,
                tables: []
            ))
            continue
        }

        if opts.ocrMode == .pdfText {
            let raw = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = page.bounds(for: .mediaBox)
            results.append(PageOCRResult(
                page: pageNum,
                widthPx: Int(bounds.width),
                heightPx: Int(bounds.height),
                extractionSource: "pdf_text",
                charCount: raw.count,
                tableCount: 0,
                listCount: 0,
                suggestedKind: classifyPageRuleBased(transcript: raw),
                titleHint: "",
                summary: "",
                transcript: raw,
                paragraphs: raw.isEmpty ? [] : [raw],
                tables: []
            ))
            continue
        }

        let cgImage: CGImage? = autoreleasepool {
            renderPDFPage(page, dpi: opts.dpi)
        }
        if let image = cgImage {
            visionQueue.append((pageNum, image))
        } else {
            fputs("Warning: Failed to render page \(pageNum)\n", stderr)
        }
    }

    if !visionQueue.isEmpty {
        let maxConcurrent = opts.concurrency
        let languages = opts.languages
        let useCorrection = opts.useLanguageCorrection
        let visionResults = try await withThrowingTaskGroup(of: PageOCRResult.self) { group in
            var nextIdx = 0
            for _ in 0..<min(maxConcurrent, visionQueue.count) {
                let item = visionQueue[nextIdx]
                nextIdx += 1
                group.addTask {
                    try await recognizeWithDocumentsAPI(
                        image: item.image,
                        pageNumber: item.pageNum,
                        languages: languages,
                        useLanguageCorrection: useCorrection
                    )
                }
            }

            var collected: [PageOCRResult] = []
            while let res = try await group.next() {
                collected.append(res)
                if nextIdx < visionQueue.count {
                    let item = visionQueue[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        try await recognizeWithDocumentsAPI(
                            image: item.image,
                            pageNumber: item.pageNum,
                            languages: languages,
                            useLanguageCorrection: useCorrection
                        )
                    }
                }
            }
            return collected
        }
        results.append(contentsOf: visionResults)
    }

    results.sort { $0.page < $1.page }
    return results
}

func runMain() async {
    guard #available(macOS 26.0, *) else {
        fputs("Error: macOS 26.0 or later is required (Vision.RecognizeDocumentsRequest)\n", stderr)
        exit(1)
    }

    guard let opts = parseArgs() else {
        exit(1)
    }

    let inputURL = URL(fileURLWithPath: (opts.inputPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        fputs("Error: File not found: \(inputURL.path)\n", stderr)
        exit(1)
    }

    let isPDF = inputURL.pathExtension.lowercased() == "pdf"
    var pageResults: [PageOCRResult] = []
    let totalPages: Int
    let apiUsed = "Vision.RecognizeDocumentsRequest + PDFKit (macOS 26+)"
    var loadedPDF: PDFDocument?

    do {
        if isPDF {
            guard let pdf = PDFDocument(url: inputURL) else {
                fputs("Error: Failed to open PDF: \(inputURL.path)\n", stderr)
                exit(1)
            }
            loadedPDF = pdf
            totalPages = pdf.pageCount
            guard totalPages > 0, let targetPages = parsePageSpec(opts.pageRangeSpec, totalPages: totalPages) else {
                exit(1)
            }
            pageResults = try await processPDF(pdf: pdf, targetPages: targetPages, opts: opts)
        } else {
            totalPages = 1
            guard let image = loadOrientedCGImage(url: inputURL) else {
                fputs("Error: Failed to load image: \(inputURL.path)\n", stderr)
                exit(1)
            }
            let res = try await recognizeWithDocumentsAPI(
                image: image,
                pageNumber: 1,
                languages: opts.languages,
                useLanguageCorrection: opts.useLanguageCorrection
            )
            pageResults.append(res)
        }

        if opts.useOnDeviceClassify {
            if case .available = SystemLanguageModel.default.availability {
                var classified: [PageOCRResult] = []
                for p in pageResults {
                    if let cls = await classifyWithFoundationModels(transcript: p.transcript, customPrompt: opts.classifyPrompt) {
                        classified.append(PageOCRResult(
                            page: p.page,
                            widthPx: p.widthPx,
                            heightPx: p.heightPx,
                            extractionSource: p.extractionSource,
                            charCount: p.charCount,
                            tableCount: p.tableCount,
                            listCount: p.listCount,
                            suggestedKind: cls.kind,
                            titleHint: cls.titleHint,
                            summary: cls.summary,
                            transcript: p.transcript,
                            paragraphs: p.paragraphs,
                            tables: p.tables
                        ))
                    } else {
                        classified.append(p)
                    }
                }
                pageResults = classified
            } else {
                fputs("Warning: Apple FoundationModels is unavailable on this Mac; using rule-based classification.\n", stderr)
            }
        }

        if let csPath = opts.contactSheetPath, let pdf = loadedPDF {
            try generateContactSheet(pdf: pdf, pageResults: pageResults, outputPath: csPath)
        } else if opts.contactSheetPath != nil && !isPDF {
            fputs("Warning: --contact-sheet is only applicable to PDF inputs; skipping.\n", stderr)
        }

        let report = DocumentOCRReport(
            inputFile: inputURL.lastPathComponent,
            apiUsed: apiUsed,
            ocrMode: opts.ocrMode.rawValue,
            languages: opts.languages,
            onDeviceClassify: opts.useOnDeviceClassify,
            totalPages: totalPages,
            processedPages: pageResults.count,
            dpi: Int(opts.dpi),
            languageCorrection: opts.useLanguageCorrection,
            pages: pageResults
        )

        let outputText: String
        if opts.format.isJson {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            outputText = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            outputText = formatMarkdown(report)
        }

        if let outPath = opts.outputPath {
            let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try outputText.write(to: outURL, atomically: true, encoding: .utf8)
            fputs("Wrote OCR report (\(pageResults.count) pages) to \(outURL.path)\n", stderr)
        } else {
            print(outputText)
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
