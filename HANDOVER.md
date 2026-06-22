# Murmel — Session-Übergabe

> Laufende Übergabe-Doku. Beim nächsten Start zuerst lesen.
> **Stand: 2026-06-22.** Murmel läuft end-to-end, installiert, alles committet & gepusht.
> **Neu (22.06.):** Live-Vorschau läuft jetzt über einen **residenten `whisper-server`** statt kalter `whisper-cli` pro Tick → ~3× schneller pro Update (gemessen 0,11 s statt 0,35 s), Takt von 1,5 s → 0,7 s. Finaler Diktat-Lauf (large-v3-turbo) unverändert.

---

## Was Murmel ist

Selbstgebautes, **100 % lokales** Voice-to-Text für macOS (Wispr-Flow-Pendant).
**fn halten → sprechen → loslassen → Text ins aktive Fenster.** Kein Abo, keine Cloud, 0 €/Monat.

- **Repo:** `github.com/alexheyers/murmel` (public, MIT) · lokal: `Documents/Claude/Projects/Murmel`
- **Stack:** Swift (SPM, kein volles Xcode) · whisper.cpp (`large-v3-turbo`) · Ollama (`qwen2.5:3b`) · SQLite
- **Eigene URL:** **murmel.vercel.app** (Standalone, Vercel-Projekt „murmel")
- **Im Portfolio:** Case-Study `/projekte/murmel.html` + Spotlight auf der Startseite + Kachel in der Beweis-Wand

## Bauen / Installieren

```bash
./Scripts/setup.sh     # whisper-cpp + large-v3-turbo (~1,5GB) + base (~150MB, Streaming) + ollama + qwen2.5:3b
./Scripts/make-cert.sh # einmalig: stabile Signatur "Murmel Code Signing"
./Scripts/make-app.sh  # baut+signiert im TEMP (außerhalb iCloud!), → dist/Murmel.app
cp -R dist/Murmel.app /Applications/ && open /Applications/Murmel.app
./Scripts/selftest.sh  # Logik-Checks ohne Xcode
```

## Features (alle gebaut & installiert)

- **Diktat** (fn-Halten) + 5 **Stil-Modi** (Roh/E-Mail/Code/Claude-Prompt/Brainstorming, pro Modus editierbar)
- **Übersetzer** (→ Englisch / → Deutsch, lokal)
- **Befehl (Zwischenablage)** — Text kopieren, Anweisung sprechen → Umwandlung
- **Assistent** (Frage→Antwort) · **Zusammenfassen**
- **Wörterbuch-Editor** + **Auto-Vorschläge** (Ollama aus Verlauf)
- **Verlauf** (SQLite, durchsuchbar) · **Sprachanalyse** (Wörter/Satz, Füllwörter, Top-Begriffe, **Wo/Top-Apps**)
- **Live-Vorschau (Streaming)** — schwebendes Overlay beim Sprechen (base-Modell via **residentem `whisper-server`**, Fallback auf `whisper-cli`), final mit large-v3-turbo
- Glas-/Apple-Look (Panel + Verwaltungsfenster mit 4 Tabs)

## Wichtige Gotchas (nicht zurückbauen!)

1. **Signatur ↔ macOS-Recht:** Bedienungshilfen-Recht hängt an der Code-Signatur. Stabile selbst-signierte Identität (`make-cert.sh`) sorgt dafür, dass das Recht über Rebuilds erhalten bleibt. Nach Identitätswechsel: `tccutil reset Accessibility de.alexheyers.murmel` + 1× neu erteilen.
2. **iCloud-Detritus:** Projekt liegt unter ~/Documents (iCloud) → `codesign` lehnt das Bundle sonst ab. `make-app.sh` baut+signiert deshalb in `mktemp -d` und kopiert dann per `ditto` nach dist/.
3. **Politur gezähmt:** Standard-Stil = `.raw`. Polish via Ollama-Chat-API + strikter System-Prompt + Halluzinations-Längen-Guard (nur für Korrektur/Übersetzung).
4. **Metriken bleiben 100 % lokal** (SQLite). Bewusste Entscheidung — KEIN Notion/Cloud (höchstens optionaler anonymer Aggregat-Sync, falls explizit gewünscht).
5. **Vorschau-Server (`WhisperServerTranscriber`):** residenter `whisper-server` auf `127.0.0.1:8771` (base-Modell), Start beim App-Launch (wenn Streaming an), Stop bei App-Terminate. Sprache wird **pro Anfrage** (`language`-Feld) mitgeschickt → ein laufender Server ist sprachunabhängig sicher. Fällt bei Nichterreichbarkeit automatisch auf `whisper-cli` zurück (Vorschau bleibt immer funktionsfähig; Server ist reine Beschleunigung). Verwaiste Server (nach SIGKILL/Crash) werden beim nächsten Start **adoptiert** statt doppelt gestartet. Nicht zurückbauen: finaler Lauf bleibt `whisper-cli`/large-v3-turbo.

## Doku & Deploys (heute aktualisiert)

- `docs/making-of.html` — Editorial-Stil, alle Features + KI-Stack-Erklärung + Abschlussbild
- `docs/praesentation.html` — **Einsteiger-Präsentation** (12 Folien): lokales LLM, Ollama, Qwen, Whisper einfach erklärt
- Portfolio Case-Study + Standalone **murmel.vercel.app** (beide mit Abschlussbild, live)
- **System-Galaxie** (claude-system-galaxie.vercel.app + Portfolio): Cluster „Lokale KI · Murmel" (Murmel/whisper.cpp/Ollama/Qwen + Verbindungen)
- Notion-Seite unter „Vibe Coding Bootcamp — Digitale Leute School"

## Offene Punkte / Nächste Ideen

- [ ] **Streaming-Overlay visuell prüfen** — Build/Logik/Modell/Server-Pfad verifiziert (inkl. echtem End-to-End-Integrationstest gegen `whisper-server`), aber das HUD konnte headless nicht gesehen werden. Alex testen lassen; Takt ist jetzt 0,7s — ggf. Position feinjustieren. **App neu bauen+installieren nötig** (`make-app.sh`), damit die Server-Vorschau greift.
- [ ] **App-Tracking füllt sich erst ab jetzt** — die ~52 Altdiktate haben kein „wo". Nach neuen Diktaten „Top-Apps" prüfen.
- [ ] **Optional:** anonymer Notion-Aggregat-Sync (nur Kennzahlen, keine Texte) — Alex hatte's erwogen, vorerst lokal belassen.
- [ ] **Optional:** `praesentation.html` als eigene Vercel-URL deployen + als LinkedIn-Carousel aufbereiten.
- [x] **Streaming dedizierter Ausbau:** ✅ ERLEDIGT 22.06. — residenter `whisper-server` statt per-Chunk `whisper-cli` (`WhisperServerTranscriber`). ~3× schneller pro Update.
- [ ] **Echtes inkrementelles Streaming (Stufe 2):** Der Server killt nur den Kaltstart — re-transkribiert pro Tick noch das GESAMTE bisherige Audio. Für noch flüssigere Vorschau bei langen Diktaten: gleitendes Fenster / VAD, nur das neue Audio verarbeiten.

## Verifikation/Fakten (geprüft)

- Analyse stimmt mit DB überein (Stand heute: 52 Diktate, 1.194 Wörter, Ø ~23).
- Anthropic-Zertifikate (Claude 101 / Claude Code in Action): „Certificate of Completion", 14.04.2026, **kein Ablauf**. Claude Code Masterclass (Everlast): gültig 14.04.2026–13.04.2028.
