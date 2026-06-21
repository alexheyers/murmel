#!/usr/bin/env bash
#
# setup.sh — installiert & prüft alles, was Murmel zur Laufzeit braucht:
#   • whisper.cpp (Befehl: whisper-cli)   — lokale Spracherkennung
#   • Whisper-Modell large-v3-turbo (deutsch, schnell auf Apple Silicon)
#   • Ollama + ein kleines LLM (qwen2.5:3b) — lokale Text-Politur
#
# Idempotent: bereits vorhandene Teile werden übersprungen.
#
set -euo pipefail

MODEL_DIR="$HOME/.murmel/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
OLLAMA_MODEL="qwen2.5:3b"

echo "=== Murmel Setup ==="

# 1) Homebrew
if ! command -v brew >/dev/null 2>&1; then
    echo "✗ Homebrew fehlt. Bitte zuerst installieren: https://brew.sh"
    exit 1
fi
echo "✓ Homebrew vorhanden"

# 2) whisper.cpp
if ! command -v whisper-cli >/dev/null 2>&1 && ! command -v whisper-cpp >/dev/null 2>&1; then
    echo "▶︎ Installiere whisper-cpp…"
    brew install whisper-cpp
else
    echo "✓ whisper.cpp vorhanden"
fi

# 3) Whisper-Modell
mkdir -p "$MODEL_DIR"
if [[ -f "$MODEL_FILE" ]]; then
    echo "✓ Whisper-Modell vorhanden ($MODEL_FILE)"
else
    echo "▶︎ Lade Whisper-Modell large-v3-turbo (~1,5 GB)…"
    curl -L --fail --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    echo "✓ Modell gespeichert: $MODEL_FILE"
fi

# 3b) Schnelles base-Modell für die Live-Vorschau (Streaming)
PREVIEW_MODEL="$MODEL_DIR/ggml-base.bin"
PREVIEW_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
if [[ -f "$PREVIEW_MODEL" ]]; then
    echo "✓ Vorschau-Modell vorhanden ($PREVIEW_MODEL)"
else
    echo "▶︎ Lade Vorschau-Modell base (~150 MB, für Live-Streaming)…"
    curl -L --fail --progress-bar -o "$PREVIEW_MODEL" "$PREVIEW_URL" \
        && echo "✓ Vorschau-Modell gespeichert" \
        || echo "⚠︎ base-Modell-Download fehlgeschlagen — Live-Vorschau bleibt aus, Rest läuft."
fi

# 4) Ollama
if ! command -v ollama >/dev/null 2>&1; then
    echo "▶︎ Installiere Ollama…"
    brew install ollama
else
    echo "✓ Ollama vorhanden"
fi

# 5) Ollama-Dienst starten (Hintergrund) + Modell ziehen
if ! curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "▶︎ Starte Ollama-Dienst…"
    (ollama serve >/dev/null 2>&1 &) || true
    sleep 3
fi

echo "▶︎ Stelle Politur-Modell sicher ($OLLAMA_MODEL)…"
ollama pull "$OLLAMA_MODEL" || echo "⚠︎ Konnte $OLLAMA_MODEL nicht ziehen — später nachholen mit: ollama pull $OLLAMA_MODEL"

echo ""
echo "=== Setup abgeschlossen ==="
echo "Tipp: Ollama muss laufen, damit die Politur greift (Stil ≠ Roh)."
echo "      Sonst fällt Murmel automatisch auf den Rohtext zurück."
