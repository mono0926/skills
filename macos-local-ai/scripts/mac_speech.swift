#!/usr/bin/env swift
// mac_speech.swift
// Zero-dependency on-device audio & video transcription via Apple SpeechAnalyzer /
// SpeechTranscriber (macOS 26+) with optional SoundAnalysis acoustic event classification.

import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis
import Speech

struct TranscriptSegment: Codable {
    let index: Int
    let startSec: Double
    let endSec: Double
    let text: String
}

struct SoundClassificationEntry: Codable {
    let identifier: String
    let maxConfidence: Double
    let occurrences: Int
}

struct SpeechReport: Codable {
    let inputFile: String
    let locale: String
    let preset: String
    let durationSec: Double
    let segmentCount: Int
    let fullTranscript: String
    let segments: [TranscriptSegment]
    let soundClassifications: [SoundClassificationEntry]
}

struct LocalesReport: Codable {
    let installed: [String]
    let supported: [String]
}

func printUsage() {
    let usage = """
    Usage:
      mac-speech locales [--format json|txt]
      mac-speech transcribe <audio_or_video_file> [options]
      mac-speech <audio_or_video_file> [options]

    Options (transcribe):
      --locale <bcp47>          Target locale (default: system locale, e.g. en-US, ja-JP)
      --install-locale          Download the speech asset automatically if supported but not installed
      --preset <accurate|fast>  Transcription preset: accurate (default) or fast
      --classify-sounds         Also detect acoustic events/music/speech via SoundAnalysis
      --format <md|txt|json|srt|vtt>  Output format (default: md)
      --out <path>              Write output to file instead of stdout
      --help, -h                Show this help message
    """
    fputs(usage + "\n", stderr)
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

func writeOutput(_ content: String, to outPath: String?) throws {
    if let outPath {
        let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        fputs("Wrote output to \(url.path)\n", stderr)
    } else {
        print(content)
    }
}

func formatTimestampSRT(_ seconds: Double) -> String {
    let totalMs = max(0, Int((seconds * 1000.0).rounded()))
    let ms = totalMs % 1000
    let totalSec = totalMs / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
}

func formatTimestampVTT(_ seconds: Double) -> String {
    let totalMs = max(0, Int((seconds * 1000.0).rounded()))
    let ms = totalMs % 1000
    let totalSec = totalMs / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

func formatClock(_ seconds: Double) -> String {
    let totalSec = max(0, Int(seconds.rounded(.down)))
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    if h > 0 {
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

func extractAudioToTempM4A(from inputURL: URL, tempDir: URL) async throws -> URL {
    let asset = AVURLAsset(url: inputURL)
    let outURL = tempDir.appendingPathComponent("extracted_audio.m4a")
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw NSError(domain: "MacSpeech", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot create AVAssetExportSession for \(inputURL.lastPathComponent)"])
    }
    try await exporter.export(to: outURL, as: .m4a)
    return outURL
}

final class SoundCollector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var maxConfidenceByLabel: [String: Double] = [:]
    private var countByLabel: [String: Int] = [:]

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let res = result as? SNClassificationResult else { return }
        lock.lock()
        defer { lock.unlock() }
        for item in res.classifications where item.confidence >= 0.15 {
            let prevMax = maxConfidenceByLabel[item.identifier] ?? 0
            if item.confidence > prevMax {
                maxConfidenceByLabel[item.identifier] = item.confidence
            }
            countByLabel[item.identifier, default: 0] += 1
        }
    }

    func summary() -> [SoundClassificationEntry] {
        lock.lock()
        defer { lock.unlock() }
        return maxConfidenceByLabel.keys
            .map { key in
                SoundClassificationEntry(
                    identifier: key,
                    maxConfidence: maxConfidenceByLabel[key] ?? 0,
                    occurrences: countByLabel[key] ?? 0
                )
            }
            .sorted { $0.maxConfidence > $1.maxConfidence }
            .prefix(10)
            .map { $0 }
    }
}

func classifySounds(audioURL: URL) throws -> [SoundClassificationEntry] {
    let analyzer = try SNAudioFileAnalyzer(url: audioURL)
    let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
    let collector = SoundCollector()
    try analyzer.add(req, withObserver: collector)
    analyzer.analyze()
    return collector.summary()
}

@available(macOS 26.0, *)
func runLocales(args: [String]) async throws {
    var format = "txt"
    var i = 0
    while i < args.count {
        if args[i] == "--format" {
            i += 1
            guard i < args.count else { throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or txt"]) }
            format = args[i].lowercased()
        } else {
            throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(args[i])"])
        }
        i += 1
    }

    let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    if format == "json" {
        print(try encodeJSON(LocalesReport(installed: installed, supported: supported)))
    } else {
        print("Installed (\(installed.count)): \(installed.joined(separator: ", "))")
        print("Supported (\(supported.count)): \(supported.joined(separator: ", "))")
    }
}

@available(macOS 26.0, *)
func runTranscribe(args: [String]) async throws {
    var inputPath: String?
    var localeIdentifier = Locale.current.identifier
    var installLocale = false
    var presetName = "accurate"
    var shouldClassifySounds = false
    var format = "md"
    var outPath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--locale":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "--locale requires a BCP-47 code"]) }
            localeIdentifier = args[i]
        case "--install-locale":
            installLocale = true
        case "--preset":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "--preset requires accurate or fast"]) }
            presetName = args[i].lowercased()
        case "--classify-sounds":
            shouldClassifySounds = true
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires md, txt, json, srt, or vtt"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if arg.hasPrefix("-") {
                throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(arg)"])
            }
            if inputPath == nil {
                inputPath = arg
            } else {
                throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Multiple input files provided: \(arg)"])
            }
        }
        i += 1
    }

    guard let rawPath = inputPath else {
        throw NSError(domain: "MacSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Media file path is required"])
    }
    let inputURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        throw NSError(domain: "MacSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "File not found: \(inputURL.path)"])
    }

    guard SpeechTranscriber.isAvailable else {
        throw NSError(domain: "MacSpeech", code: 4, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber is not available on this Mac."])
    }

    let requestedLocale = Locale(identifier: localeIdentifier)
    guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted().joined(separator: ", ")
        throw NSError(
            domain: "MacSpeech",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Locale '\(localeIdentifier)' is not supported. Supported: \(supported)"]
        )
    }

    let preset: SpeechTranscriber.Preset = (presetName == "fast")
        ? .timeIndexedProgressiveTranscription
        : .timeIndexedTranscriptionWithAlternatives

    let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset)
    let installedLocales = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
    let assetStatus = await AssetInventory.status(forModules: [transcriber])
    if assetStatus != .installed && !installedLocales.contains(resolvedLocale.identifier) {
        if installLocale {
            fputs("Downloading speech asset for \(resolvedLocale.identifier)...\n", stderr)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        } else {
            throw NSError(
                domain: "MacSpeech",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Speech asset for '\(resolvedLocale.identifier)' is not installed. Re-run with --install-locale to download it."]
            )
        }
    }

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac_speech_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let videoExtensions = Set(["mp4", "mov", "m4v", "mkv", "avi"])
    let audioURL: URL
    if videoExtensions.contains(inputURL.pathExtension.lowercased()) {
        audioURL = try await extractAudioToTempM4A(from: inputURL, tempDir: tempDir)
    } else if let directAudio = try? AVAudioFile(forReading: inputURL) {
        _ = directAudio
        audioURL = inputURL
    } else {
        audioURL = try await extractAudioToTempM4A(from: inputURL, tempDir: tempDir)
    }

    let audioFile = try AVAudioFile(forReading: audioURL)
    let durationSec = Double(audioFile.length) / audioFile.fileFormat.sampleRate

    let analyzer = try await SpeechAnalyzer(
        inputAudioFile: audioFile,
        modules: [transcriber],
        finishAfterFile: true
    )

    var rawSegments: [(start: Double, end: Double, text: String)] = []
    for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let start = max(0, result.range.start.seconds)
        let end = max(start, result.range.end.seconds)
        if let last = rawSegments.last, abs(last.start - start) < 0.05 {
            rawSegments[rawSegments.count - 1] = (start, end, text)
        } else {
            rawSegments.append((start, end, text))
        }
    }
    _ = analyzer

    let segments = rawSegments.enumerated().map { idx, seg in
        TranscriptSegment(index: idx + 1, startSec: seg.start, endSec: seg.end, text: seg.text)
    }
    let fullTranscript = segments.map(\.text).joined(separator: " ")

    var sounds: [SoundClassificationEntry] = []
    if shouldClassifySounds {
        sounds = try classifySounds(audioURL: audioURL)
    }

    let report = SpeechReport(
        inputFile: inputURL.lastPathComponent,
        locale: resolvedLocale.identifier,
        preset: presetName,
        durationSec: durationSec,
        segmentCount: segments.count,
        fullTranscript: fullTranscript,
        segments: segments,
        soundClassifications: sounds
    )

    let outputText: String
    switch format {
    case "json":
        outputText = try encodeJSON(report)
    case "txt":
        outputText = fullTranscript
    case "srt":
        outputText = segments.map { seg in
            "\(seg.index)\n\(formatTimestampSRT(seg.startSec)) --> \(formatTimestampSRT(seg.endSec))\n\(seg.text)"
        }.joined(separator: "\n\n")
    case "vtt":
        let cues = segments.map { seg in
            "\(formatTimestampVTT(seg.startSec)) --> \(formatTimestampVTT(seg.endSec))\n\(seg.text)"
        }.joined(separator: "\n\n")
        outputText = "WEBVTT\n\n" + cues
    default:
        var md: [String] = []
        md.append("# Transcript: \(report.inputFile)")
        md.append(String(format: "- Locale: `%@` | Preset: `%@` | Duration: %.1fs | Segments: %d", report.locale, report.preset, report.durationSec, report.segmentCount))
        if !sounds.isEmpty {
            let labels = sounds.map { String(format: "%@ (%.0f%%)", $0.identifier, $0.maxConfidence * 100) }.joined(separator: ", ")
            md.append("- Sounds Detected: \(labels)")
        }
        md.append("")
        md.append("## Segments")
        for seg in segments {
            md.append("- `[\(formatClock(seg.startSec)) - \(formatClock(seg.endSec))]` \(seg.text)")
        }
        outputText = md.joined(separator: "\n")
    }

    try writeOutput(outputText, to: outPath)
}

func runMain() async {
    guard #available(macOS 26.0, *) else {
        fputs("Error: macOS 26.0 or later is required (Speech.SpeechAnalyzer)\n", stderr)
        exit(1)
    }

    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args[0] == "--help" || args[0] == "-h" {
        printUsage()
        exit(args.isEmpty ? 1 : 0)
    }

    do {
        if args[0] == "locales" {
            try await runLocales(args: Array(args.dropFirst()))
        } else if args[0] == "transcribe" {
            try await runTranscribe(args: Array(args.dropFirst()))
        } else {
            try await runTranscribe(args: args)
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
