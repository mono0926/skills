---
name: macos-local-ai
description: Use native macOS APIs (Vision, PDFKit, SpeechAnalyzer, Translation, NaturalLanguage, FoundationModels, /usr/bin/fm) and built-in CLIs (sips, qlmanage, mdfind, afconvert, textutil) to offload OCR, audio/video transcription, image cutouts/cropping, barcode reading, offline translation, local embeddings, and text triage on Apple Silicon Macs when output quality is preserved or improved.
---

# macOS Local AI & Native API Offload (`macos-local-ai`)

Offload deterministic perception, media processing, search, and lightweight triage to native Apple Silicon frameworks and built-in macOS CLI tools—achieving **zero cloud token cost, near-instant execution, and strict local privacy without sacrificing output quality**.

> [!IMPORTANT]
> **Core Principle: Zero-Quality-Loss Routing**
> Never substitute an on-device ~3B LLM where deep reasoning, complex coding, math verification, or subtle visual judgment is required. Use local macOS tools where they are **equal or superior** to cloud APIs (exact OCR, deterministic NLP, Apple Neural Engine speech transcription, pixel-accurate foreground masking, Spotlight search) or as a **pre-screening / PII-scrubbing stage** ahead of a frontier model.

---

## Decision Matrix (Tier 1 / Tier 2 / Tier 3)

| Tier | Workload | Recommended Local Tool / API | Why Local Wins (or Guardrail) |
| :--- | :--- | :--- | :--- |
| **🟢 Tier 1: Always Prefer Local** | Printed PDF / document / screenshot OCR & table extraction | `scripts/mac-ocr` (`PDFKit` + `Vision.RecognizeDocumentsRequest`) | Deterministic embedded PDF text extraction + ANE layout-aware OCR with tables, reading order, and labeled contact-sheet PNGs. |
| **🟢 Tier 1: Always Prefer Local** | Foreground cutout (transparent PNG) | `scripts/mac-vision cutout` (`VNGenerateForegroundInstanceMaskRequest`) | Pixel-accurate alpha mask without generative re-drawing artifacts. |
| **🟢 Tier 1: Always Prefer Local** | Document edge detection & perspective rectification | `scripts/mac-vision doc-crop` (`DetectDocumentSegmentationRequest`) | Exact corner coordinates + `CIPerspectiveCorrection`, zero text distortion. |
| **🟢 Tier 1: Always Prefer Local** | QR / barcode decoding | `scripts/mac-vision barcodes` (`DetectBarcodesRequest`) | Deterministic symbology decoding (`payload`, coordinates, GS1 flag). |
| **🟢 Tier 1: Always Prefer Local** | Audio / video timestamped transcription & sound tagging | `scripts/mac-speech` (`SpeechAnalyzer` + `SoundAnalysis`) | Apple Neural Engine transcription (`md`/`txt`/`json`/`srt`/`vtt`) without Python/Whisper dependencies. |
| **🟢 Tier 1: Always Prefer Local** | Offline neural translation (installed packs) | `scripts/mac-nlp translate` (`TranslationSession`) | Fast offline translation; fails cleanly with instructions if the language pack is not downloaded. |
| **🟢 Tier 1: Always Prefer Local** | Language ID, word/sentence counts, NER, semantic dedup | `scripts/mac-nlp analyze` / `similarity` (`NaturalLanguage`) | Exact tokenization, `NLTagger` entities, and `NLEmbedding` cosine similarity. |
| **🟢 Tier 1: Always Prefer Local** | Image resize/convert, thumbnails, Spotlight search, `.docx` extract | `sips`, `qlmanage -t`, `mdfind`, `mdls`, `afconvert`, `textutil` | Built-in OS binaries; zero setup, milliseconds latency. See `references/builtin-macos-cli.md`. |
| **🟡 Tier 2: Hybrid / Guardrailed** | Multi-page PDF pre-screening, schema tagging, log triage, verbatim PII masking | `/usr/bin/fm` (macOS 27+), `scripts/mac-ocr --classify`, `scripts/mac-nlp triage` | Uses `@Generable` / JSON schema and verbatim substring replacement so untouched text never drifts. |
| **🔴 Tier 3: Keep on Frontier Cloud** | Complex coding, architecture, math proofs, faint/cursive handwriting grading, nuanced UI/UX critique | **Do NOT replace with local 3B models** | Use local tools only to crop, transcribe, or build contact sheets—then inspect with the frontier model. |

---

## Bundled Zero-Dependency Tools (`scripts/`)

Every wrapper in `scripts/` compiles its companion `.swift` source once with `swiftc -O` and caches the native binary (keyed by source hash + `swiftc` version). Subsequent runs start with virtually zero overhead and require **no Python, Homebrew, or pip packages** (macOS 26+ required; macOS 27+ for `/usr/bin/fm`).

### 1. `scripts/mac-ocr` — Document & Image OCR + Contact Sheet
```bash
# Extract text + tables from a PDF (auto-uses embedded PDF text, falls back to parallel Vision OCR)
scripts/mac-ocr document.pdf --format md --out /tmp/ocr.md

# Screen a large PDF: generate a 4-column contact sheet PNG + on-device page triage
scripts/mac-ocr textbook.pdf --classify --contact-sheet /tmp/sheet.png --format json --out /tmp/report.json

# OCR code screenshots or IDs without spellcheck auto-correction
scripts/mac-ocr terminal.png --no-lang-correction --langs en-US
```
- Key flags: `--pages 1-5,8`, `--dpi 200`, `--ocr-mode auto|vision|pdf-text`, `--langs en-US,ja-JP`, `--concurrency 4`, `--classify`, `--classify-prompt "..."`, `--contact-sheet out.png`, `--format md|json`.

### 2. `scripts/mac-vision` — Cutouts, Document Crop, Barcodes, Image Inspection
```bash
# Extract foreground subject onto a transparent RGBA PNG (tightly cropped)
scripts/mac-vision cutout photo.heic --out /tmp/subject.png --crop

# Deskew a photographed paper sheet and normalize uneven lighting
scripts/mac-vision doc-crop receipt.jpg --out /tmp/receipt_flat.png --normalize-lighting

# Decode QR codes and barcodes with normalized [ymin, xmin, ymax, xmax] boxes
scripts/mac-vision barcodes label.png --format json

# Inspect dimensions, aesthetics score, utility flag, face/text counts, and top labels
scripts/mac-vision inspect screenshot.png --top 8 --format md
```

### 3. `scripts/mac-speech` — Audio & Video Transcription (`SpeechAnalyzer`)
```bash
# Check installed and supported speech locales
scripts/mac-speech locales

# Transcribe audio or video (.mp4/.mov/.m4a/.wav) with timestamps + sound labels
scripts/mac-speech meeting.mp4 --locale en-US --format md --classify-sounds --out /tmp/transcript.md

# Export SRT/VTT subtitles (auto-downloading the locale pack if needed)
scripts/mac-speech interview.m4a --locale ja-JP --install-locale --format srt --out /tmp/subtitles.srt
```
- Key flags: `--locale <bcp47>`, `--install-locale`, `--preset accurate|fast`, `--classify-sounds`, `--format md|txt|json|srt|vtt`.

### 4. `scripts/mac-nlp` — Deterministic NLP, Offline Translation, Embeddings & Triage
```bash
# Language detection, exact token counts, and named entities
scripts/mac-nlp analyze notes.txt --format json

# Offline neural translation (requires installed macOS Translation language pack)
scripts/mac-nlp translate --from ja --to en --text "ローカルAIで高速に処理できます。"

# Local semantic search & near-duplicate detection across lines or JSONL
scripts/mac-nlp similarity --inputs items.txt --query "memory leak in image cache" --top 5 --dedup-threshold 0.88

# Guardrailed on-device FoundationModels triage (classify / tags / redact-pii / extract-kv)
scripts/mac-nlp triage log.txt --mode redact-pii --format json
scripts/mac-nlp triage ticket.txt --mode classify --categories "bug,feature,question,billing"
```
> **How `redact-pii` preserves quality**: Regex handles emails, phone numbers, card numbers, and IPs, while `NLTagger` + `FoundationModels` identify verbatim name/address substrings that are replaced directly in the original string—preventing 3B LLM paraphrasing drift.

---

## Multi-Stage Hybrid Workflows (Best ROI)

1. **Large PDF Analysis (Saves 80–95% Vision Tokens)**
   - Run `scripts/mac-ocr input.pdf --classify --contact-sheet /tmp/sheet.png --format json --out /tmp/ocr.json`.
   - Read `/tmp/sheet.png` once with the frontier multimodal model to spot diagrams/cover pages, and use `/tmp/ocr.json` text for text-only pages—opening high-res page renders only where diagrams or complex layouts require visual inspection.
2. **Long Video / Meeting Digest**
   - Run `scripts/mac-speech recording.mp4 --format json --out /tmp/transcript.json`.
   - Pass the clean text transcript (not raw audio/video) to the frontier model for deep synthesis, action items, and technical critique.
3. **Privacy-Safe Log / Document Cloud Analysis**
   - Run `scripts/mac-nlp triage raw.txt --mode redact-pii --format md --out /tmp/sanitized.txt`.
   - Inspect `/tmp/sanitized.txt` before sending sensitive context to external services.

---

## Built-in macOS CLI & Custom Swift References

- **Built-in OS CLIs** (`/usr/bin/fm`, `sips`, `qlmanage`, `mdfind`, `mdls`, `afconvert`, `avmediainfo`, `say`, `textutil`, `shortcuts`): Read `references/builtin-macos-cli.md`.
- **Custom Swift Patterns** (`FoundationModels`, `CoreAI`, `Vision`, `SpeechAnalyzer`, `Translation`, `NaturalLanguage`): Read `references/swift-api-patterns.md`.

### `/usr/bin/fm` Quick Check (macOS 27+)
Before scripting against `/usr/bin/fm`, verify `fm models` shows `✓ system`. If it reports that the Legal Notice & Terms have not been accepted, prompt the user to run `sudo fm license` once in Terminal. Always pass `--no-stream` (and `-g` for deterministic outputs) when invoking `fm respond` from scripts.
