# Built-in macOS CLI Recipes for AI Agents

When performing everyday file, media, search, and lightweight on-device LLM tasks on macOS, prefer these pre-installed OS binaries before writing custom Python scripts or sending raw binary payloads to cloud models.

---

## 1. `/usr/bin/fm` — Apple Foundation Models CLI (macOS 27+)

macOS 27 ships `/usr/bin/fm`, exposing Apple's on-device `AFM 3 Core Advanced` model directly from the shell.

### First-Time Setup & Availability Check
```bash
fm models
# Output when ready:
#   ✓ system (AFM 3 Core Advanced)
# If prompted to agree to Legal Notice & Terms, ask the user to run once:
#   sudo fm license
```

### Fast Non-Streaming Prompts & Pipes
Always pass `--no-stream` in scripts/agents so output is clean and buffered, and `-g` (`--greedy`) for deterministic classification or extraction.

```bash
# Deterministic classification / short answer
fm respond --no-stream -g 'Classify this error as auth, network, or syntax. Reply with one word: "HTTP 401 token expired"'

# Pipe stdin content with instructions
cat notes.txt | fm respond --no-stream -g --instructions "Extract action items as concise markdown bullets."

# Dedicated content-tagging system model
fm respond --no-stream --use-case content-tagging 'Swift 6 concurrency actor isolation migration guide'
```

### Guardrails for Summarizing / Scrubbing Untrusted Text
When summarizing logs, bug reports, or external web/email text that might contain sensitive keywords, use `--guardrails permissive-content-transformations` to avoid false-positive refusals:

```bash
fm respond --no-stream --guardrails permissive-content-transformations \
  --instructions "Summarize the incident timeline in 3 bullets." \
  "$(cat incident_log.txt)"
```

### Schema-Constrained Structured JSON (`fm schema object`)
Combine `fm schema object` with `--schema` to guarantee valid JSON output from the on-device 3B model:

```bash
SCHEMA=$(fm schema object --name IssueTriage \
  --string severity --description "low, medium, high, or critical" \
  --string component --description "affected subsystem" \
  --string summary --description "one-sentence summary")

fm respond --no-stream -g --schema <(printf '%s' "$SCHEMA") \
  --instructions "Triage this bug report." \
  "App crashes on macOS when opening a 0-byte PDF."
```

### Multimodal Input with Built-in Vision Tools (`--image`, `--tool`)
`fm respond` can inspect an image directly and invoke built-in `ocr` or `barcode` tools:

```bash
fm respond --no-stream --image receipt.jpg --tool ocr --text "Extract merchant name, date, and total."
fm respond --no-stream --image label.png --tool barcode --text "Read the barcode value."
```

### Token Counting & OpenAI-Compatible Local Server
```bash
# Count tokens before calling FoundationModels
fm count-tokens "Your prompt text here"

# Optional local Chat Completions endpoint for local dev tools
fm serve --help
```

---

## 2. `sips` — Scriptable Image Processing System

Built-in, GPU-accelerated image format conversion, resizing, cropping, and metadata inspection (supports HEIC, PNG, JPEG, TIFF, WebP, GIF, BMP).

```bash
# Inspect image dimensions, format, color space, DPI
sips -g pixelWidth -g pixelHeight -g format -g dpiWidth photo.heic

# Convert HEIC / WebP / TIFF to PNG (lossless, preserves transparency)
sips -s format png input.heic --out output.png

# Convert and downscale large screenshots before passing to multimodal LLMs
sips -s format jpeg -s formatOptions 85 --resampleHeightWidthMax 1600 huge.png --out preview.jpg

# Batch convert a folder of HEIC photos to PNG
mkdir -p out_png && sips -s format png *.heic --out out_png/

# Auto-rotate / flip
sips -r 90 image.png --out rotated.png
```

---

## 3. `qlmanage` — Quick Look Thumbnailing

Generates crisp PNG thumbnails for **PDFs, Keynote, Pages, Word (`.docx`), Excel (`.xlsx`), USDZ 3D models, images, and videos** in milliseconds without opening any GUI app.

```bash
# Render a 1024px PNG thumbnail of a PDF, DOCX, or USDZ file
qlmanage -t -s 1024 -o /tmp/thumbs document.pdf
# Output: /tmp/thumbs/document.pdf.png

# Batch thumbnail multiple files
qlmanage -t -s 800 -o /tmp/thumbs *.pdf *.docx
```

---

## 4. `mdfind` & `mdls` — Instant CoreSpotlight Search & Metadata

Instead of running slow recursive `grep`/`find` across large folders or Downloads/Desktop, query macOS's pre-built Spotlight index instantaneously.

```bash
# Find PDFs containing a phrase, scoped to a specific folder
mdfind -onlyin ~/Documents 'kMDItemContentType == "com.adobe.pdf" && kMDItemTextContent == "*invoice*"cd'

# Find files modified in the last 3 days
mdfind -onlyin . 'kMDItemFSContentChangeDate >= $time.today(-3)'

# Inspect all indexed metadata for a file (duration, dimensions, codecs, author)
mdls recording.mov
mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth -name kMDItemPixelHeight clip.mp4
```

---

## 5. `afconvert`, `afinfo`, `avmediainfo`, `say` — Audio & Media Utilities

Zero-dependency audio inspection, conversion, and local text-to-speech synthesis.

```bash
# Inspect audio sample rate, channels, bit rate, and duration
afinfo audio.m4a

# Inspect video/audio tracks, codecs, chapters, and metadata
avmediainfo video.mp4 --brief
avmediainfo video.mp4 --metadata asset

# Transcode audio to 16kHz mono PCM WAV or compact AAC M4A
afconvert input.aiff -d LEI16@16000 -c 1 -f WAVE output_16k.wav
afconvert input.wav -d aac -f m4af -b 128000 output.m4a

# Synthesize spoken audio locally (useful for test fixtures or audio previews)
say -v Samantha -o sample.aiff "Testing local speech recognition."
```

---

## 6. `textutil` — Document Text & Format Conversion

Converts `.docx`, `.doc`, `.rtf`, `.rtfd`, `.html`, and `.webarchive` files cleanly to plain text, Markdown-friendly HTML, or `.docx` without Python `python-docx` or LibreOffice.

```bash
# Extract plain text from Word / RTF / HTML to stdout
textutil -convert txt -stdout report.docx

# Batch convert RTF notes to UTF-8 plain text
textutil -convert txt -encoding UTF-8 *.rtf

# Convert Markdown-exported HTML to .docx
textutil -convert docx summary.html -output summary.docx
```

---

## 7. `shortcuts` & `osascript` — System Automation

```bash
# List and run user-configured Apple Shortcuts headlessly
shortcuts list
shortcuts run "Convert Clipboard to Markdown"

# Run JXA (JavaScript for Automation) when inspecting macOS app state or plist/JSON
osascript -l JavaScript -e 'Application("System Events").processes.name()'
```
