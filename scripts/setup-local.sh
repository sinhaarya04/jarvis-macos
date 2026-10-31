#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v brew >/dev/null; then
  echo 'Install Homebrew from https://brew.sh, then rerun this script.' >&2
  exit 1
fi
if ! command -v whisper-cli >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install whisper.cpp
fi
if ! command -v ollama >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install ollama
fi
mkdir -p .runtime/models
if ! curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; then
  echo 'Starting a local-only Ollama server.'
  OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 nohup ollama serve > .runtime/ollama.log 2>&1 &
  for attempt in {1..20}; do
    if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; then break; fi
    sleep 1
  done
fi
OLLAMA_HOST=127.0.0.1:11434 ollama pull qwen3.5:0.8b
MODEL=.runtime/models/ggml-base.en.bin
EXPECTED=a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
if [ ! -f "$MODEL" ]; then
  curl --fail --location --retry 2 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin' -o "$MODEL.part"
  ACTUAL=$(shasum -a 256 "$MODEL.part" | cut -d ' ' -f 1)
  [ "$ACTUAL" = "$EXPECTED" ] || { echo 'Speech model checksum mismatch.' >&2; exit 1; }
  mv "$MODEL.part" "$MODEL"
fi
ACTUAL=$(shasum -a 256 "$MODEL" | cut -d ' ' -f 1)
[ "$ACTUAL" = "$EXPECTED" ] || { echo 'Speech model checksum mismatch.' >&2; exit 1; }
echo 'Local models ready. No paid endpoints were configured.'
