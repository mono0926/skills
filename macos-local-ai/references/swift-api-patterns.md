# Swift Native API Patterns (macOS 26 / 27+)

Reference patterns for writing ad-hoc, zero-dependency Swift CLI utilities on Apple Silicon Macs when the bundled `scripts/mac-*` tools do not cover a specialized task.

---

## 1. Zero-Dependency Cached CLI Pattern

Compile single-file Swift scripts once with `swiftc -O` and cache the binary by source hash + `swiftc --version` (see `scripts/_compile_and_run.sh`). For async entrypoints, drive `RunLoop.main.run()` and call `exit(0)` on completion:

```swift
#!/usr/bin/env swift
import Foundation

func runMain() async {
    // Async framework calls here
}

Task {
    await runMain()
    exit(0)
}
RunLoop.main.run()
```

---

## 2. `FoundationModels` (On-Device LLM with `@Generable` & `@Tool`)

Available on macOS 26+ Apple Silicon Macs with Apple Intelligence enabled. Always check `SystemLanguageModel.default.availability` first.

```swift
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct ExtractedRecord: Codable {
    @Guide(description: "Document category")
    var category: String
    @Guide(description: "Concise list of key entities")
    var entities: [String]
}

@available(macOS 26.0, *)
func runOnDeviceLLM(prompt: String) async throws -> ExtractedRecord? {
    guard case .available = SystemLanguageModel.default.availability else {
        return nil
    }
    let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )
    let session = LanguageModelSession(
        model: model,
        instructions: "Extract structured metadata faithfully without adding external facts."
    )
    let response = try await session.respond(to: prompt, generating: ExtractedRecord.self)
    return response.content
}
```

### `CoreAI` Framework (macOS 27+)
When loading custom PyTorch/CoreML-converted models locally (`aimodelc` / `.aimodel` bundles) without Python runtimes, use `CoreAI.framework` for Apple Silicon neural-engine acceleration.

---

## 3. `Vision` Modern Swift Concurrency APIs (macOS 26+)

### Structured Document OCR (`RecognizeDocumentsRequest`)
Extracts full text, paragraphs, reading order, lists, and table cells (`doc.tables`):

```swift
import Vision

@available(macOS 26.0, *)
func extractDocument(from cgImage: CGImage) async throws {
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = [
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "ja-JP")
    ]
    request.textRecognitionOptions.useLanguageCorrection = true

    let observations = try await request.perform(on: cgImage)
    guard let doc = observations.first?.document else { return }
    print(doc.text.transcript)
    for table in doc.tables {
        let rows = table.rows.map { row in
            row.map { $0.content.text.transcript }
        }
        print(rows)
    }
}
```

### Document Boundary & Perspective Rectification (`DetectDocumentSegmentationRequest`)
Both `Vision.NormalizedPoint` (default `.lowerLeft`) and `CoreImage` (`CIImage`) use bottom-left origin coordinates:

```swift
import CoreImage
import Vision

@available(macOS 26.0, *)
func rectifyDocument(cgImage: CGImage) async throws -> CIImage? {
    let request = DetectDocumentSegmentationRequest()
    guard let obs = try await request.perform(on: cgImage) else { return nil }

    let ciImage = CIImage(cgImage: cgImage)
    let size = ciImage.extent.size
    let filter = CIFilter(name: "CIPerspectiveCorrection")!
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgPoint: obs.topLeft.toImageCoordinates(size, origin: .lowerLeft)), forKey: "inputTopLeft")
    filter.setValue(CIVector(cgPoint: obs.topRight.toImageCoordinates(size, origin: .lowerLeft)), forKey: "inputTopRight")
    filter.setValue(CIVector(cgPoint: obs.bottomLeft.toImageCoordinates(size, origin: .lowerLeft)), forKey: "inputBottomLeft")
    filter.setValue(CIVector(cgPoint: obs.bottomRight.toImageCoordinates(size, origin: .lowerLeft)), forKey: "inputBottomRight")
    return filter.outputImage
}
```

### Foreground Subject Masking (`GenerateForegroundInstanceMaskRequest`)
```swift
import CoreImage
import Vision

@available(macOS 26.0, *)
func extractSubjectCutout(cgImage: CGImage, crop: Bool) async throws -> CIImage? {
    let handler = ImageRequestHandler(cgImage)
    let request = GenerateForegroundInstanceMaskRequest()
    guard let obs = try await handler.perform(request) else { return nil }
    let pixelBuffer = try obs.generateMaskedImage(
        for: obs.allInstances,
        imageFrom: handler,
        croppedToInstancesExtent: crop
    )
    return CIImage(cvPixelBuffer: pixelBuffer)
}
```

### Barcodes, Aesthetics, Faces, Text Regions
- `DetectBarcodesRequest().perform(on: cgImage)` -> `[BarcodeObservation]` (`payloadString`, `symbology`, `boundingRegion`, `confidence`)
- `CalculateImageAestheticsScoresRequest().perform(on: cgImage)` -> `ImageAestheticsScoresObservation` (`overallScore`, `isUtility`)
- `ClassifyImageRequest().perform(on: cgImage)` -> `[ClassificationObservation]` (`identifier`, `confidence`)

---

## 4. `Speech` (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+)

Runs on the Apple Neural Engine without Python or Whisper model downloads when system speech assets are installed:

```swift
import AVFoundation
import Speech

@available(macOS 26.0, *)
func transcribeAudioFile(url: URL, locale: Locale) async throws -> [(Double, Double, String)] {
    let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    let transcriber = SpeechTranscriber(
        locale: resolved,
        preset: .timeIndexedTranscriptionWithAlternatives
    )

    if await AssetInventory.status(forModules: [transcriber]) != .installed {
        if let installReq = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installReq.downloadAndInstall()
        }
    }

    let audioFile = try AVAudioFile(forReading: url)
    let analyzer = try await SpeechAnalyzer(
        inputAudioFile: audioFile,
        modules: [transcriber],
        finishAfterFile: true
    )

    var segments: [(Double, Double, String)] = []
    for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            segments.append((result.range.start.seconds, result.range.end.seconds, text))
        }
    }
    _ = analyzer
    return segments
}
```

---

## 5. `Translation` & `NaturalLanguage`

### Headless Neural Translation (macOS 15+)
Requires the offline language pack to be installed on-device:

```swift
import Translation

@available(macOS 15.0, *)
func translateOffline(text: String, from: String, to: String) async throws -> String {
    let src = Locale.Language(identifier: from)
    let dst = Locale.Language(identifier: to)
    let status = await LanguageAvailability().status(from: src, to: dst)
    guard status == .installed else {
        throw NSError(domain: "Translation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language pack not installed"])
    }
    let session = TranslationSession(installedSource: src, target: dst)
    return try await session.translate(text).targetText
}
```

### Sentence Embeddings (`NLEmbedding`) & Entity Tagging (`NLTagger`)
- `NLLanguageRecognizer` detects dominant language and probabilities.
- `NLTokenizer(unit: .word | .sentence | .paragraph)` counts units deterministically across CJK and Latin scripts.
- `NLTagger(tagSchemes: [.nameType])` extracts `.personalName`, `.placeName`, `.organizationName`.
- `NLEmbedding.sentenceEmbedding(for:)` returns dense sentence vectors for local cosine similarity and near-duplicate clustering.
