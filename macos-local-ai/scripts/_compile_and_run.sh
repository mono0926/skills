#!/usr/bin/env bash
# Shared cached Swift compiler & launcher for macos-local-ai CLI tools.
# Compiles each single-file Swift utility once with -O and caches the binary
# keyed by source SHA-256 + swiftc version so subsequent runs start instantly.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: macos-local-ai tools require macOS (Darwin)." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc not found. Install Xcode or Xcode Command Line Tools (xcode-select --install)." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: _compile_and_run.sh <swift_filename> [args...]" >&2
  exit 1
fi

SWIFT_FILE="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/$SWIFT_FILE"

if [[ ! -f "$SRC" ]]; then
  echo "Error: Swift source not found: $SRC" >&2
  exit 1
fi

SRC_HASH="$(shasum -a 256 "$SRC" | awk '{print substr($1, 1, 16)}')"
SWIFTC_HASH="$(swiftc --version 2>/dev/null | head -n 1 | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
STEM="${SWIFT_FILE%.swift}"

DEFAULT_CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/macos-local-ai/bin"
CACHE_DIR="${MACOS_LOCAL_AI_CACHE_DIR:-$DEFAULT_CACHE_BASE}"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null || [[ ! -w "$CACHE_DIR" ]]; then
  CACHE_DIR="/tmp/macos-local-ai-bin-$(id -u)"
  mkdir -p "$CACHE_DIR"
fi

BIN="$CACHE_DIR/${STEM}_${SRC_HASH}_${SWIFTC_HASH}"

if [[ ! -x "$BIN" ]]; then
  TMP_BIN="${BIN}.tmp.$$"
  swiftc -O "$SRC" -o "$TMP_BIN"
  mv -f "$TMP_BIN" "$BIN"
fi

exec "$BIN" "$@"
