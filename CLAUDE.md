# CLAUDE.md — Murmel

> Diese Datei wird automatisch gelesen, wenn eine Session im Murmel-Ordner startet.

## SESSION-START — Pflicht

Wenn die Session in diesem Repo startet **oder** Alex „**starte Murmel**" sagt:

1. **`HANDOVER.md` lesen** (im Repo-Root) — das ist die laufende Übergabe / Single Source of Truth.
2. **Kurz zusammenfassen**, BEVOR neue Arbeit beginnt:
   - Was war die **letzte Session** (was wurde gemacht)?
   - Aktueller **Stand** (läuft/installiert, Repo, URLs)?
   - **Offene Punkte** aus HANDOVER.md.
3. **Git/Deploy-Status prüfen** und melden:
   - `git status` (sauber? ungepusht?) für dieses Repo **und** das Portfolio (`../alexander-heyers-portfolio`)
   - kurzer Hinweis, ob `murmel.vercel.app` + Portfolio aktuell deployt sind.
4. Erst danach: fragen/loslegen.

## Projekt-Kurzfakten

- **Was:** lokales Voice-to-Text für macOS (Wispr-Flow-Pendant), 100 % offline, 0 €.
- **Repo:** `github.com/alexheyers/murmel` (public, MIT). **Eigene URL:** `murmel.vercel.app`.
- **Stack:** Swift (SPM) · whisper.cpp (`large-v3-turbo`) · Ollama (`qwen2.5:3b`) · SQLite.
- **Bauen:** `Scripts/setup.sh` → `Scripts/make-cert.sh` → `Scripts/make-app.sh` → `dist/Murmel.app`. Test: `Scripts/selftest.sh`.

## Harte Regeln (aus HANDOVER, nicht zurückbauen)

- App-Bundle IMMER in `mktemp -d` bauen+signieren (iCloud-Detritus-Fix), dann per `ditto` nach `dist/`.
- Stabile Signatur „Murmel Code Signing" (sonst stirbt das macOS-Recht bei Rebuilds).
- Standard-Stil `.raw`; Politur via Ollama mit striktem Prompt + Halluzinations-Guard.
- **Metriken bleiben 100 % lokal** (SQLite) — kein Notion/Cloud ohne ausdrückliche Ansage.
- **Live-Vorschau = residenter `whisper-server`** (`WhisperServerTranscriber`, `127.0.0.1:8771`, base-Modell), Fallback auf `whisper-cli`. Sprache pro Anfrage mitschicken. Finaler Lauf bleibt `whisper-cli`/large-v3-turbo — NICHT auf den Server umstellen.
