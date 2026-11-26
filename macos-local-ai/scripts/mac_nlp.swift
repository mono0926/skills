#!/usr/bin/env swift
// mac_nlp.swift
// Deterministic NLP (NaturalLanguage), offline neural translation (Translation),
// local sentence embeddings (NLEmbedding), and guardrailed FoundationModels triage (macOS 26+).

import Foundation
import FoundationModels
import NaturalLanguage
import Translation

struct AnalyzeReport: Codable {
    let dominantLanguage: String?
    let languageHypotheses: [String: Double]
    let charCount: Int
    let wordCount: Int
    let sentenceCount: Int
    let paragraphCount: Int
    let entities: EntitiesReport
}

struct EntitiesReport: Codable {
    let people: [String]
    let places: [String]
    let organizations: [String]
}

struct TranslateReport: Codable {
    let sourceLanguage: String
    let targetLanguage: String
    let translations: [TranslationItem]
}

struct TranslationItem: Codable {
    let source: String
    let target: String
}

struct SimilarityMatch: Codable {
    let index: Int
    let id: String
    let text: String
    let similarity: Double
}

struct DuplicatePair: Codable {
    let indexA: Int
    let idA: String
    let indexB: Int
    let idB: String
    let similarity: Double
}

struct SimilarityReport: Codable {
    let language: String
    let itemCount: Int
    let embeddedCount: Int
    let query: String?
    let matches: [SimilarityMatch]
    let duplicatePairs: [DuplicatePair]
}

@available(macOS 26.0, *)
@Generable
struct TriageClassifyResult: Codable {
    @Guide(description: "Selected category label")
    var category: String
    @Guide(description: "Confidence level: high, medium, or low")
    var confidenceHint: String
    @Guide(description: "One short sentence explaining the classification")
    var reason: String
}

@available(macOS 26.0, *)
@Generable
struct TriageTagsResult: Codable {
    @Guide(description: "3 to 7 concise lowercase topic tags")
    var tags: [String]
    @Guide(description: "Primary topic in a few words")
    var topic: String
    @Guide(description: "Primary language BCP-47 code such as en or ja")
    var language: String
}

@available(macOS 26.0, *)
@Generable
struct PIIDetectionResult: Codable {
    @Guide(description: "Exact verbatim person names, street addresses, or organization account IDs found in the text")
    var sensitiveStrings: [String]
}

@available(macOS 26.0, *)
@Generable
struct KeyValueEntry: Codable {
    var key: String
    var value: String
}

@available(macOS 26.0, *)
@Generable
struct ExtractKVResult: Codable {
    @Guide(description: "Extracted key-value pairs matching the requested keys; empty string if missing")
    var items: [KeyValueEntry]
}

struct RedactPIIReport: Codable {
    let redactedText: String
    let regexRedactionCount: Int
    let modelEntityRedactionCount: Int
    let detectedEntities: [String]
}

func printUsage() {
    let usage = """
    Usage:
      mac-nlp <subcommand> [options]

    Subcommands:
      analyze [<file|->] [--text <str>] [--format json|md] [--out <path>]
          Deterministic language detection, token counts, and named entity recognition (NLTagger).

      translate [<file|->] [--text <str>] --from <lang> --to <lang> [--batch-lines] [--format txt|json] [--out <path>]
          Offline neural translation via Apple Translation framework (requires installed language pack).

      similarity --inputs <txt_or_jsonl> [--query <str>] [--lang <code_or_auto>] [--top 10] [--dedup-threshold 0.85] [--format json|md] [--out <path>]
          Local sentence embedding ranking and near-duplicate detection via NLEmbedding.

      triage [<file|->] [--text <str>] --mode <classify|tags|redact-pii|extract-kv> [options]
          Guardrailed on-device FoundationModels triage:
            --categories <a,b,c>     Allowed labels for classify mode
            --keys <k1,k2,k3>        Target fields for extract-kv mode
            --instructions <text>    Additional instructions
            --format <json|md>       Output format (default: json)
            --out <path>             Write output to file
    """
    fputs(usage + "\n", stderr)
}

func readInputText(positional: String?, explicitText: String?) throws -> String {
    if let explicitText {
        return explicitText
    }
    guard let positional else {
        throw NSError(domain: "MacNLP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provide input text via --text <str>, a file path, or '-' for stdin"])
    }
    if positional == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    let expanded = (positional as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
        return try String(contentsOfFile: expanded, encoding: .utf8)
    }
    return positional
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

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

func countTokens(in text: String, unit: NLTokenUnit) -> Int {
    let tokenizer = NLTokenizer(unit: unit)
    tokenizer.string = text
    var count = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
        count += 1
        return true
    }
    return count
}

func runAnalyze(args: [String]) throws {
    var positional: String?
    var explicitText: String?
    var format = "json"
    var outPath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--text":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--text requires a value"]) }
            explicitText = args[i]
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or md"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if arg.hasPrefix("-") && arg != "-" {
                throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(arg)"])
            }
            positional = arg
        }
        i += 1
    }

    let text = try readInputText(positional: positional, explicitText: explicitText)
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let dominant = recognizer.dominantLanguage?.rawValue
    let hypotheses = Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 5).map { ($0.key.rawValue, $0.value) })

    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    var people = Set<String>()
    var places = Set<String>()
    var orgs = Set<String>()
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
        guard let tag else { return true }
        let value = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        switch tag {
        case .personalName: people.insert(value)
        case .placeName: places.insert(value)
        case .organizationName: orgs.insert(value)
        default: break
        }
        return true
    }

    let report = AnalyzeReport(
        dominantLanguage: dominant,
        languageHypotheses: hypotheses,
        charCount: text.count,
        wordCount: countTokens(in: text, unit: .word),
        sentenceCount: countTokens(in: text, unit: .sentence),
        paragraphCount: countTokens(in: text, unit: .paragraph),
        entities: EntitiesReport(
            people: people.sorted(),
            places: places.sorted(),
            organizations: orgs.sorted()
        )
    )

    if format == "md" {
        var md: [String] = []
        md.append("# NLP Analysis")
        md.append("- Dominant Language: `\(report.dominantLanguage ?? "unknown")`")
        md.append("- Counts: \(report.charCount) chars, \(report.wordCount) words, \(report.sentenceCount) sentences, \(report.paragraphCount) paragraphs")
        md.append("- People: \(report.entities.people.isEmpty ? "_none_" : report.entities.people.joined(separator: ", "))")
        md.append("- Places: \(report.entities.places.isEmpty ? "_none_" : report.entities.places.joined(separator: ", "))")
        md.append("- Organizations: \(report.entities.organizations.isEmpty ? "_none_" : report.entities.organizations.joined(separator: ", "))")
        try writeOutput(md.joined(separator: "\n"), to: outPath)
    } else {
        try writeOutput(try encodeJSON(report), to: outPath)
    }
}

@available(macOS 15.0, *)
func runTranslate(args: [String]) async throws {
    var positional: String?
    var explicitText: String?
    var fromLang: String?
    var toLang: String?
    var batchLines = false
    var format = "txt"
    var outPath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--text":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--text requires a value"]) }
            explicitText = args[i]
        case "--from":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--from requires a language code"]) }
            fromLang = args[i]
        case "--to":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--to requires a language code"]) }
            toLang = args[i]
        case "--batch-lines":
            batchLines = true
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires txt or json"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if arg.hasPrefix("-") && arg != "-" {
                throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(arg)"])
            }
            positional = arg
        }
        i += 1
    }

    guard let fromCode = fromLang, let toCode = toLang else {
        throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Both --from <lang> and --to <lang> are required"])
    }

    let text = try readInputText(positional: positional, explicitText: explicitText)
    let srcLang = Locale.Language(identifier: fromCode)
    let dstLang = Locale.Language(identifier: toCode)

    let availability = LanguageAvailability()
    let status = await availability.status(from: srcLang, to: dstLang)
    switch status {
    case .installed:
        break
    case .supported:
        throw NSError(
            domain: "MacNLP",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Offline translation pack for \(fromCode) -> \(toCode) is supported but not installed. Download it in System Settings > General > Language & Region > Translation Languages."]
        )
    case .unsupported:
        throw NSError(
            domain: "MacNLP",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Translation pair \(fromCode) -> \(toCode) is unsupported by Apple Translation."]
        )
    @unknown default:
        break
    }

    let session = TranslationSession(installedSource: srcLang, target: dstLang)
    var items: [TranslationItem] = []

    if batchLines {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)") }
        let responses = try await session.translations(from: requests)
        items = responses.map { TranslationItem(source: $0.sourceText, target: $0.targetText) }
    } else {
        let res = try await session.translate(text)
        items = [TranslationItem(source: res.sourceText, target: res.targetText)]
    }

    if format == "json" {
        let report = TranslateReport(sourceLanguage: fromCode, targetLanguage: toCode, translations: items)
        try writeOutput(try encodeJSON(report), to: outPath)
    } else {
        try writeOutput(items.map(\.target).joined(separator: "\n"), to: outPath)
    }
}

struct InputEntry {
    let id: String
    let text: String
}

struct InputJSONLine: Decodable {
    let id: String?
    let text: String
}

func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    let denom = sqrt(normA) * sqrt(normB)
    return denom > 0 ? dot / denom : 0
}

func runSimilarity(args: [String]) throws {
    var inputsPath: String?
    var query: String?
    var langCode = "auto"
    var topK = 10
    var dedupThreshold: Double?
    var format = "json"
    var outPath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--inputs":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--inputs requires a file path"]) }
            inputsPath = args[i]
        case "--query":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--query requires text"]) }
            query = args[i]
        case "--lang":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--lang requires a code"]) }
            langCode = args[i]
        case "--top":
            i += 1
            guard i < args.count, let val = Int(args[i]), val >= 1 else {
                throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--top requires a positive integer"])
            }
            topK = val
        case "--dedup-threshold":
            i += 1
            guard i < args.count, let val = Double(args[i]), val >= 0, val <= 1 else {
                throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--dedup-threshold requires a number between 0.0 and 1.0"])
            }
            dedupThreshold = val
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or md"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(arg)"])
        }
        i += 1
    }

    guard let path = inputsPath else {
        throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--inputs <txt_or_jsonl> is required"])
    }
    let expanded = (path as NSString).expandingTildeInPath
    let raw = try String(contentsOfFile: expanded, encoding: .utf8)
    let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

    let decoder = JSONDecoder()
    var entries: [InputEntry] = []
    for (idx, line) in lines.enumerated() {
        if line.hasPrefix("{"), let data = line.data(using: .utf8), let parsed = try? decoder.decode(InputJSONLine.self, from: data) {
            entries.append(InputEntry(id: parsed.id ?? "\(idx)", text: parsed.text))
        } else {
            entries.append(InputEntry(id: "\(idx)", text: line))
        }
    }

    let resolvedLang: NLLanguage
    if langCode == "auto" {
        let sample = ([query].compactMap { $0 } + entries.prefix(20).map(\.text)).joined(separator: "\n")
        let rec = NLLanguageRecognizer()
        rec.processString(sample)
        resolvedLang = rec.dominantLanguage ?? .english
    } else {
        resolvedLang = NLLanguage(rawValue: langCode)
    }

    guard let embedding = NLEmbedding.sentenceEmbedding(for: resolvedLang) else {
        throw NSError(
            domain: "MacNLP",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Sentence embedding is unavailable for language '\(resolvedLang.rawValue)'."]
        )
    }

    var vectors: [(idx: Int, entry: InputEntry, vec: [Double])] = []
    for (idx, entry) in entries.enumerated() {
        if let vec = embedding.vector(for: entry.text) {
            vectors.append((idx, entry, vec))
        }
    }

    var matches: [SimilarityMatch] = []
    if let query {
        guard let qVec = embedding.vector(for: query) else {
            throw NSError(domain: "MacNLP", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not compute embedding vector for --query."])
        }
        matches = vectors
            .map { SimilarityMatch(index: $0.idx, id: $0.entry.id, text: $0.entry.text, similarity: cosineSimilarity(qVec, $0.vec)) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(topK)
            .map { $0 }
    }

    var dupPairs: [DuplicatePair] = []
    if let threshold = dedupThreshold {
        for a in 0..<vectors.count {
            for b in (a + 1)..<vectors.count {
                let sim = cosineSimilarity(vectors[a].vec, vectors[b].vec)
                if sim >= threshold {
                    dupPairs.append(DuplicatePair(
                        indexA: vectors[a].idx,
                        idA: vectors[a].entry.id,
                        indexB: vectors[b].idx,
                        idB: vectors[b].entry.id,
                        similarity: sim
                    ))
                }
            }
        }
        dupPairs.sort { $0.similarity > $1.similarity }
    }

    let report = SimilarityReport(
        language: resolvedLang.rawValue,
        itemCount: entries.count,
        embeddedCount: vectors.count,
        query: query,
        matches: matches,
        duplicatePairs: dupPairs
    )

    if format == "md" {
        var md: [String] = []
        md.append("# Local Sentence Similarity (`\(report.language)`)")
        md.append("- Embedded: \(report.embeddedCount) / \(report.itemCount) items")
        if !matches.isEmpty {
            md.append("")
            md.append("## Top Matches")
            for m in matches {
                md.append(String(format: "- `[%.4f]` (%@) %@", m.similarity, m.id, m.text))
            }
        }
        if !dupPairs.isEmpty {
            md.append("")
            md.append("## Near-Duplicate Pairs")
            for p in dupPairs {
                md.append(String(format: "- `[%.4f]` %@ <-> %@", p.similarity, p.idA, p.idB))
            }
        }
        try writeOutput(md.joined(separator: "\n"), to: outPath)
    } else {
        try writeOutput(try encodeJSON(report), to: outPath)
    }
}

func regexReplace(_ text: String, pattern: String, replacement: String) -> (String, Int) {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return (text, 0)
    }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.numberOfMatches(in: text, options: [], range: nsRange)
    if matches == 0 {
        return (text, 0)
    }
    let updated = regex.stringByReplacingMatches(in: text, options: [], range: nsRange, withTemplate: replacement)
    return (updated, matches)
}

@available(macOS 26.0, *)
func runTriage(args: [String]) async throws {
    var positional: String?
    var explicitText: String?
    var mode: String?
    var categories: String?
    var keys: String?
    var extraInstructions: String?
    var format = "json"
    var outPath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--text":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--text requires a value"]) }
            explicitText = args[i]
        case "--mode":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--mode requires classify|tags|redact-pii|extract-kv"]) }
            mode = args[i].lowercased()
        case "--categories":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--categories requires comma-separated labels"]) }
            categories = args[i]
        case "--keys":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--keys requires comma-separated fields"]) }
            keys = args[i]
        case "--instructions":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--instructions requires text"]) }
            extraInstructions = args[i]
        case "--format":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--format requires json or md"]) }
            format = args[i].lowercased()
        case "--out":
            i += 1
            guard i < args.count else { throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--out requires a path"]) }
            outPath = args[i]
        default:
            if arg.hasPrefix("-") && arg != "-" {
                throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(arg)"])
            }
            positional = arg
        }
        i += 1
    }

    guard let mode else {
        throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "--mode <classify|tags|redact-pii|extract-kv> is required"])
    }
    guard case .available = SystemLanguageModel.default.availability else {
        throw NSError(domain: "MacNLP", code: 7, userInfo: [NSLocalizedDescriptionKey: "Apple FoundationModels is unavailable on this Mac."])
    }

    let text = try readInputText(positional: positional, explicitText: explicitText)
    let snippet = String(text.prefix(4000))

    switch mode {
    case "classify":
        let catClause = categories.map { "Allowed categories: \($0)." } ?? "Choose a concise, descriptive category label."
        let instructions = extraInstructions ?? "Classify the input accurately. \(catClause)"
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let res = try await session.respond(to: snippet, generating: TriageClassifyResult.self).content
        if format == "md" {
            try writeOutput("- Category: `\(res.category)` (`\(res.confidenceHint)`)\n- Reason: \(res.reason)", to: outPath)
        } else {
            try writeOutput(try encodeJSON(res), to: outPath)
        }

    case "tags":
        let instructions = extraInstructions ?? "Extract concise topic tags and primary topic."
        let model = SystemLanguageModel(useCase: .contentTagging, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let res = try await session.respond(to: snippet, generating: TriageTagsResult.self).content
        if format == "md" {
            try writeOutput("- Topic: \(res.topic) (`\(res.language)`)\n- Tags: \(res.tags.joined(separator: ", "))", to: outPath)
        } else {
            try writeOutput(try encodeJSON(res), to: outPath)
        }

    case "redact-pii":
        var working = text
        var regexCount = 0
        let patterns: [(String, String)] = [
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[REDACTED_EMAIL]"),
            ("(?:\\+?\\d{1,3}[\\s-]?)?(?:\\(?\\d{2,4}\\)?[\\s-]?)\\d{3,4}[\\s-]\\d{4}", "[REDACTED_PHONE]"),
            ("\\b(?:\\d{4}[\\s-]?){3}\\d{4}\\b", "[REDACTED_CARD]"),
            ("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", "[REDACTED_IP]")
        ]
        for (pattern, placeholder) in patterns {
            let (updated, count) = regexReplace(working, pattern: pattern, replacement: placeholder)
            working = updated
            regexCount += count
        }

        // Detect named PII via NLTagger + on-device LLM, then perform exact substring replacement
        // so non-PII text remains 100% verbatim without paraphrasing drift.
        var candidates = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = working
        tagger.enumerateTags(in: working.startIndex..<working.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                let token = String(working[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if token.count >= 2 { candidates.insert(token) }
            }
            return true
        }

        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(
            model: model,
            instructions: extraInstructions ?? "List exact verbatim substrings representing personal names, street addresses, or personal IDs in the text. Return only exact strings present in the input."
        )
        if let detected = try? await session.respond(to: String(working.prefix(3500)), generating: PIIDetectionResult.self).content {
            for item in detected.sensitiveStrings {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2 && !trimmed.hasPrefix("[REDACTED_") {
                    candidates.insert(trimmed)
                }
            }
        }

        let sortedEntities = candidates.sorted { $0.count > $1.count }
        var appliedEntities: [String] = []
        var entityCount = 0
        for entity in sortedEntities {
            if working.contains(entity) {
                let occurrences = working.components(separatedBy: entity).count - 1
                working = working.replacingOccurrences(of: entity, with: "[REDACTED_PII]")
                entityCount += max(1, occurrences)
                appliedEntities.append(entity)
            }
        }

        let report = RedactPIIReport(
            redactedText: working,
            regexRedactionCount: regexCount,
            modelEntityRedactionCount: entityCount,
            detectedEntities: appliedEntities
        )
        if format == "md" {
            try writeOutput(working, to: outPath)
        } else {
            try writeOutput(try encodeJSON(report), to: outPath)
        }

    case "extract-kv":
        let keyClause = keys.map { "Requested keys: \($0)." } ?? "Extract key factual attributes as concise key-value pairs."
        let instructions = extraInstructions ?? "Extract exact factual values from the text. \(keyClause)"
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let res = try await session.respond(to: snippet, generating: ExtractKVResult.self).content
        if format == "md" {
            let lines = res.items.map { "- **\($0.key)**: \($0.value)" }
            try writeOutput(lines.joined(separator: "\n"), to: outPath)
        } else {
            try writeOutput(try encodeJSON(res), to: outPath)
        }

    default:
        throw NSError(domain: "MacNLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported --mode '\(mode)'"])
    }
}

func runMain() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args[0] == "--help" || args[0] == "-h" {
        printUsage()
        exit(args.isEmpty ? 1 : 0)
    }

    let subcommand = args[0]
    let rest = Array(args.dropFirst())

    do {
        switch subcommand {
        case "analyze":
            try runAnalyze(args: rest)
        case "translate":
            guard #available(macOS 15.0, *) else {
                throw NSError(domain: "MacNLP", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS 15.0 or later is required for Translation."])
            }
            try await runTranslate(args: rest)
        case "similarity":
            try runSimilarity(args: rest)
        case "triage":
            guard #available(macOS 26.0, *) else {
                throw NSError(domain: "MacNLP", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS 26.0 or later is required for FoundationModels triage."])
            }
            try await runTriage(args: rest)
        default:
            fputs("Error: Unknown subcommand '\(subcommand)'\n", stderr)
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
