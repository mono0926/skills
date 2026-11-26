---
name: google-colab-gpu
description: Decide when and how to offload GPU/TPU workloads to Google Colab (Google AI Pro/Ultra or Colab Pro/Pro+) via the official `colab` CLI (`colab-operator`), the official hosted MCP endpoint (`https://colaboratory.googleapis.com/mcp`), or 24-hour background notebooks. Use for on-device ML/CV training & quantization (CoreML/LiteRT/ONNX), heavy CV/hyperparameter sweeps, open OCR/VLM benchmarks, and high-VRAM media generation while avoiding CU waste and data leakage.
---

# Google Colab GPU Offload & Routing Guide (`google-colab-gpu`)

Use this skill to decide **when** to offload compute to Google Colab, **which GPU tier** fits the job cost-effectively, and **which execution interface** (`colab` CLI vs. hosted MCP vs. background notebook) to choose without burning Compute Units (CUs) or leaking sensitive data.

> [!NOTE]
> For detailed `colab` CLI command syntax, session lifecycle, file transfer, and `--auth=adc` setup, pair this skill with the official **`colab-operator`** skill (`googlecolab/google-colab-cli`).

---

## 1. Routing Matrix: Colab GPU vs. Local Machine vs. Frontier Cloud API

| Workload | Recommended Target | Rationale |
| :--- | :--- | :--- |
| **ML/CV training & quantization** (e.g., segmentation, object detection, LoRA, CoreML / LiteRT / ONNX export) | **Colab GPU** (`L4` / `A100` / `H100`) | Orders of magnitude faster than local laptop GPUs; preserves local responsiveness. |
| **Large-scale CV / hyperparameter sweeps** (OpenCV + Optuna, synthetic dataset evaluation) | **Colab CPU / L4** | Reproducible Python/CUDA environment with parallel trials and fast visual plots. |
| **Open OCR / layout / VLM benchmarks** (e.g., YomiToku, PaddleOCR, Surya, open VLMs) | **Colab GPU** (`L4` / `A100` / `G4 96GB`) | Easy apples-to-apples comparison before committing to cloud GPU hosting or on-device export. |
| **High-VRAM media generation** (video/image/TTS models requiring 24–96 GB VRAM) | **Colab GPU** (`A100 80GB` / `G4 96GB`) | Exceeds consumer GPU memory; avoids per-minute third-party GPU billing when covered by a Google AI plan. |
| **Lightweight local tasks** (printed PDF OCR, quick analysis, Flutter/Xcode builds, unit tests) | **Local Machine** (e.g., `macos-local-ai`) | Zero startup latency, zero CU burn, native OS APIs, and strict local privacy. |
| **Complex reasoning & production app inference** (nuanced grading, pedagogy/hints, live user APIs) | **Frontier Cloud API** (e.g., Gemini API / Server Prompt Templates) | Never use Colab as a production API server; do not replace frontier reasoning with self-hosted LLMs unless explicitly justified. |

---

## 2. Execution Interface Selection

Choose the lowest-friction, safest interface for the job:

1. **Ephemeral one-shot jobs (Preferred for agents)**: Official `colab` CLI (`uv tool install google-colab-cli`, see `colab-operator`)
   ```bash
   colab run --gpu L4 train.py --epochs 10
   ```
   - Provisions a fresh VM, streams script `stdout`, propagates exit codes, and **automatically tears down the VM even on error** (zero idle CU burn).
   - For headless agent runs, prefer `--auth=adc` with the 4 required OAuth scopes documented in `colab-operator`.
2. **Stateful / interactive agent control**: Official hosted MCP endpoint (`https://colaboratory.googleapis.com/mcp`, REST `colaboratory.googleapis.com`, OAuth 2.0)
   - Standard flow: `get_subscription` / `list_runtime_specs` -> `create_runtime` -> `create_session` -> `execute_code` -> **always `delete_runtime`** on completion or failure.
   - Or persistent `colab` CLI sessions: `colab new -s <name> --gpu L4` -> `colab exec -s <name> -f script.py` -> `colab stop -s <name>`.
3. **Long-running training (up to 24h on Google AI Ultra / Colab Pro+)**: Background execution
   - Always save checkpoints periodically to durable storage (Google Drive / GCS / artifact store).
   - Always terminate the runtime automatically at the end of the final cell/script:
     ```python
     from google.colab import runtime
     runtime.unassign()
     ```

---

## 3. GPU Selection & CU Conservation

Colab CU burn rates vary dynamically by accelerator and RAM profile, and granted CUs typically expire after 90 days. Match hardware to the phase of work:

| Tier | Typical VRAM | Best For |
| :--- | :--- | :--- |
| **CPU / T4** | 0 / 16 GB | Debugging, data prep, smoke tests, lightweight inference |
| **L4** | 24 GB | Default best cost-performance for medium training, CV sweeps, OCR benchmarks |
| **A100** | 40 / 80 GB | Main deep learning training runs and multi-run sweeps |
| **G4** (RTX PRO 6000 Blackwell) | 96 GB | Maximum VRAM workloads (video models, large open VLMs, high-res media/LoRA) |
| **H100** | 80 GB | Maximum throughput when available on eligible top tiers (e.g., Ultra / Pro+) |

- **Rule of thumb**: Prototype on CPU or `T4`/`L4` first; escalate to `A100`/`G4`/`H100` only after a short smoke run passes cleanly.
- **Never leave runtimes idle**: Idle connected sessions keep consuming CUs. Prefer `colab run` (auto-teardown) or explicit `colab stop` / `delete_runtime` / `runtime.unassign()`.

---

## 4. Data Hygiene & Legal Guardrails

- **No raw PII or copyrighted scans in cloud runtimes**: Avoid uploading personal photos, student/customer records, or copyrighted commercial scans to Colab or Google Drive.
- **Prefer synthetic or public datasets**: Generate clean synthetic training/benchmark pairs (e.g., programmatic PDF/image rendering + synthetic augmentations) or use properly licensed public datasets.
- **Keep weights & datasets out of Git**: Store only reproducible notebooks, training scripts, and evaluation configs in version control; keep large datasets and model checkpoints in `.gitignore`d or external artifact storage.
