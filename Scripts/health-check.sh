#!/usr/bin/env bash
#
# health-check.sh — täglicher Murmel-Gesundheitscheck.
# Prüft alle Teile (App, Ollama+Modelle, whisper-server, Wissens-Index, Config, Platte),
# heilt die App bei Bedarf (Neustart), schreibt einen Bericht und zeigt eine macOS-Notiz.
# Wird per LaunchAgent jeden Morgen ausgeführt (siehe Scripts/health-check.plist).
#
set -o pipefail

MURMEL_HOME="$HOME/.murmel"
LOG="$MURMEL_HOME/health.log"
mkdir -p "$MURMEL_HOME"

ok=()
issues=()
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# 1) Murmel-App — bei Bedarf neu starten (Self-Healing).
if pgrep -f "Murmel.app/Contents/MacOS/Murmel" >/dev/null 2>&1; then
  ok+=("Murmel-App laeuft")
else
  if open -a /Applications/Murmel.app >/dev/null 2>&1; then
    sleep 3
    issues+=("Murmel-App war aus -> automatisch neu gestartet")
  else
    issues+=("Murmel-App aus UND Neustart fehlgeschlagen")
  fi
fi

# 2) Ollama erreichbar + Pflicht-Modelle vorhanden.
if curl -s -m 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  models="$(curl -s -m 5 http://127.0.0.1:11434/api/tags | tr ',' '\n' | grep -o '"name":"[^"]*"' | sed 's/.*"name":"//;s/"//')"
  ok+=("Ollama erreichbar")
  for m in "qwen2.5:3b" "nomic-embed-text"; do
    echo "$models" | grep -q "$m" || issues+=("Ollama-Modell fehlt: $m")
  done
else
  issues+=("Ollama NICHT erreichbar (127.0.0.1:11434)")
fi

# 3) whisper-server (Murmel spawnt ihn beim Start; nur informativ).
if pgrep -f "whisper-server" >/dev/null 2>&1; then
  ok+=("whisper-server laeuft")
else
  issues+=("whisper-server aus (startet beim naechsten Diktat)")
fi

# 4) Wissens-Index.
if command -v sqlite3 >/dev/null 2>&1; then
  chunks="$(sqlite3 "$MURMEL_HOME/knowledge.sqlite" 'SELECT count(*) FROM chunks;' 2>/dev/null)"
  files="$(sqlite3 "$MURMEL_HOME/knowledge.sqlite" 'SELECT count(DISTINCT path) FROM chunks;' 2>/dev/null)"
  if [ "${chunks:-0}" -gt 0 ] 2>/dev/null; then
    ok+=("Wissens-Index: ${chunks} Chunks / ${files} Dateien")
  else
    issues+=("Wissens-Index leer")
  fi
fi

# 5) Config (zur Kontrolle: Stil, Voice-Agent).
style="$(defaults read de.alexheyers.murmel murmel.style 2>/dev/null || echo '?')"
conv="$(defaults read de.alexheyers.murmel murmel.conversationEnabled 2>/dev/null || echo '?')"
ok+=("Config: Stil=${style}, Voice-Agent=${conv}")

# 6) Freier Speicher.
ok+=("Frei: $(df -h / | awk 'NR==2{print $4}')")

# --- Bericht schreiben ---
{
  echo "===== Murmel Health-Check $(ts) ====="
  for o in "${ok[@]}"; do echo "  [OK] $o"; done
  if [ "${#issues[@]}" -eq 0 ]; then
    echo "  => ALLES GRUEN"
  else
    for i in "${issues[@]}"; do echo "  [!]  $i"; done
  fi
  echo ""
} >> "$LOG"

# --- macOS-Notiz ---
if [ "${#issues[@]}" -eq 0 ]; then
  osascript -e 'display notification "Alles laeuft." with title "Murmel Health-Check ✅"' >/dev/null 2>&1
else
  msg="$(printf '%s | ' "${issues[@]}")"
  osascript -e "display notification \"${msg}\" with title \"Murmel Health-Check ⚠️\"" >/dev/null 2>&1
fi

# Exit-Code: 0 wenn alles gruen, sonst 1 (fuer manuelle Aufrufe nützlich).
[ "${#issues[@]}" -eq 0 ]
