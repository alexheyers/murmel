# Murmel — Session-Übergabe

> Laufende Übergabe-Doku. Beim nächsten Start zuerst lesen.
> **Stand: 2026-06-23.** Murmel läuft end-to-end, installiert, alles committet (push offen — prüfen!).
>
> **Neu (23.06.) — Murmel wird zum sprechenden Voice-Agenten:**
> 1. **Modus „Strukturiert"** (Commit `c253708`): gliedert diktierten Fließtext in Absätze (wortgetreu). Auto-Routing für Messenger (WhatsApp/Messages/Slack/Telegram). Reiches app-bewusstes Formatieren folgt mit 7B (3B zu schwach, live verifiziert).
> 2. **Voice-Agent-Spec**: `docs/superpowers/specs/2026-06-23-murmel-voice-agent-design.md` — Vision (fn steuert alles), 5 Bausteine, gestufte Eskalation, Hybrid (lokal 7B Standard / Cloud Spitze). **Making-of**: `docs/making-of-voice-agent.html` (LinkedIn-fertig).
> 3. **Eigene Stimme „Thorsten" (Piper)**: neuronal, lokal, gratis, unter `~/.claude/tts/` (venv + de_DE-thorsten-medium). macOS-Binary war kaputt → pip-venv-Weg (Python 3.14 + onnxruntime cp314).
> 4. **Terminal spricht**: Claude-Code Stop-Hook (`~/.claude/tts/stop-hook.py`, in `~/.claude/settings.json`) liest Antworten mit Thorsten vor. Mute: `touch ~/.claude/tts/mute`. **Aktiv ab nächstem Claude-Code-Start.**
> 5. **Gesprächs-Modus auf rechter ⌥** (Commits `831652b` + `45d7a7d`): halten → sprechen → Thorsten antwortet GESPROCHEN (kein Text). `ConversationEngine` (Ollama-Chat + Verlauf, 7B→3B-Fallback, **RAG-geerdet** auf indexierten Daten) + `PiperSpeaker` (Fallback System-`say`). Eigene Töne (Submarine/Morse/Hero). **Default-Modell qwen2.5:7B (gezogen).** Build + Selbsttest grün, live verifiziert.
> 6. **App neu gebaut + installiert** (`make-app.sh` → `/Applications/Murmel.app`). Beide Hotkeys aktiv (Log bestätigt).
>
> **✅ Notion-Connector GEBAUT (23.06., Commit `b921e8a`):** Gesprächs-Modus ist live geerdet auf der **BIZ-26-Notion**. `NotionClient` (`/v1/search` + `/v1/blocks`) hängt im RAG-Retriever (`AppCoordinator`), merged lokale Datei-Treffer + Notion. Token in App-UserDefaults (`defaults write de.alexheyers.murmel murmel.notionToken …` — NICHT im Repo). Build+Selbsttest grün, live verifiziert (Notion→7B→Thorsten). **Caveat:** Notions Suche ist keyword-basiert (nicht semantisch) → lange Gesprächsfragen treffen mvariabel; ggf. Keyword-Extraktion vor der Suche nachrüsten. Optional Weg B (Notion→lokaler Index, offline) später.
>
> **Offen / nächste Scheibe (priorisiert):**
> - **Retrieval-Qualität Notion:** Keyword-Extraktion aus der Frage vor `/v1/search` (bessere Treffer), evtl. Datenbank-spezifische Suche (Architektur-Bausteine, Command Center, CRM).
> - **Index ist LEER (0 Chunks).** Für „Kai auf lokalen Dateien" muss Alex einmal indexieren (App → Verwaltung → Wissens-Assistent).
> - **Gmail / „alle lokalen Dateien"-Connector**: eigene Sync/Tool-Features (nächste Scheiben).
> - **Hands-free-Session**: ⌥ lang halten (>3s) → Thorsten begrüßt → freihändiger Dialog (braucht Sprechpausen-Erkennung/VAD).
> - **Erledigt 23.06.:** git push ✅ (bis `911e213`), Notion-Doku ✅ (Seite unter „P2 · Murmel").
>
> ---
> **Stand davor: 2026-06-22.** Murmel läuft end-to-end, installiert, alles committet & gepusht.
> **Neu (22.06.):**
> 1. **Vorschau-Server:** Live-Vorschau läuft jetzt über einen **residenten `whisper-server`** statt kalter `whisper-cli` pro Tick → ~3× schneller pro Update (gemessen 0,11 s statt 0,35 s), Takt 1,5 s → 0,7 s. Finaler Lauf (large-v3-turbo) unverändert.
> 2. **Overlay-Fix (wichtig!):** Das Vorschau-Fenster war faktisch unsichtbar — Bug: Accessory-App ist nie „aktiv", Panel versteckte sich sofort wieder. Fix: `hidesOnDeactivate = false` + Floating-Panel-Flags in `LiveOverlay`. Per Log verifiziert (`visible=true`, Frame im unteren Bildschirmdrittel).
> 3. **Slash-Befehle:** „slash context" → `/context` (kleingeschrieben, angehängt), deutsche Verhörer gemappt („slash klar" → `/clear`), eigene Commands funktionieren generisch. In `VoiceCommandProcessor`.
> 4. **Eigenname „Murmel":** als Vokabel ergänzt (inkl. Verhörer „MoMel"). Wörterbuch **merged** jetzt fehlende Defaults in bestehende `vokabular.json`, ohne eigene Einträge zu überschreiben.
> 5. **Eingabe-Qualität:** Prompt-Biasing (Whisper bekommt Eigennamen/Befehle als `--prompt` / Server-`prompt`-Feld → erkennt n8n/Supabase/Claude/Murmel direkt richtig), `-sns` (suppress-non-speech) + `TranscriptHygiene`-Filter gegen Stille-Halluzinationen (`*Piep*`/`[Musik]`), optional VAD (`--vad`, Modell via `setup.sh`). Windowed Streaming: Vorschau transkribiert nur die letzten 10 s.
> 6. **Auto-Modus pro App** (`AppStyleMapper`): im Roh-Modus wählt Murmel den Stil nach aktiver App (Terminal→Roh, Mail→E-Mail, Notion/Obsidian→Brainstorming). Manuelle Stilwahl bleibt unangetastet. Toggle „Modus automatisch je App". Default AN.
> 7. **Vorlesen / TTS** (`Speaker`, AVSpeechSynthesizer, de-DE): liest Assistent-/Zusammenfassen-Antworten nach dem Einfügen vor (Toggle „Antworten vorlesen", Default AUS) + Menü „Zwischenablage vorlesen"/„Vorlesen stoppen".
> 9. **Installer / Verteilung:** In-App-Ersteinrichtung (`SetupManager` + `SetupView` + `SetupWindow`) — beim ersten Start prüft Murmel whisper.cpp/Modelle/Ollama/Qwen und installiert Fehlendes mit Zwischenfrage + Fortschritt (Voraussetzung Homebrew; wird erkannt+angeleitet). Menü-Eintrag „Einrichtung & Status prüfen". `Scripts/release.sh <version> [--publish]` baut signierte `.dmg`+`.zip` (sauber, ohne iCloud-Detritus) + optional GitHub-Release via `gh`. README hat „Installation (Download)". **Gatekeeper:** selbst-signiert → Nutzer muss `xattr -dr com.apple.quarantine` (Notarisierung bräuchte Apple-Dev-Account 99 €/J). Artefakte v0.1.0 lokal gebaut+verifiziert, **noch NICHT veröffentlicht** (wartet auf Alex' OK).
> 8. **Wissens-Assistent kuratiert:** Indexer-Müll-Filter (node_modules, .build, Pods, DerivedData … + 2-MB-Limit + text-artige Endungen), Default-Ordner `~/Documents/Claude/Projects` + OneDrive + iCloud (nur existierende), Indexierung bleibt nutzergetriggert. **Ehrliche Grenze:** reine Cloud/Browser + „allwissend" gehen NICHT lokal — qwen 3B beantwortet RAG-Treffer, kein Genie.

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

- [x] **Streaming-Overlay sichtbar** — ✅ FIX 22.06. Das HUD war durch `hidesOnDeactivate` unsichtbar; jetzt per Log bestätigt sichtbar (`visible=true`). Falls Position/Takt (0,7s) noch nerven: Alex sagt Bescheid, dann feinjustieren.
- [ ] **App-Tracking füllt sich erst ab jetzt** — die ~52 Altdiktate haben kein „wo". Nach neuen Diktaten „Top-Apps" prüfen.
- [ ] **Optional:** anonymer Notion-Aggregat-Sync (nur Kennzahlen, keine Texte) — Alex hatte's erwogen, vorerst lokal belassen.
- [ ] **Optional:** `praesentation.html` als eigene Vercel-URL deployen + als LinkedIn-Carousel aufbereiten.
- [x] **Streaming dedizierter Ausbau:** ✅ ERLEDIGT 22.06. — residenter `whisper-server` statt per-Chunk `whisper-cli` (`WhisperServerTranscriber`). ~3× schneller pro Update.
- [ ] **Echtes inkrementelles Streaming (Stufe 2):** Der Server killt nur den Kaltstart — re-transkribiert pro Tick noch das GESAMTE bisherige Audio. Für noch flüssigere Vorschau bei langen Diktaten: gleitendes Fenster / VAD, nur das neue Audio verarbeiten.

## Verifikation/Fakten (geprüft)

- Analyse stimmt mit DB überein (Stand heute: 52 Diktate, 1.194 Wörter, Ø ~23).
- Anthropic-Zertifikate (Claude 101 / Claude Code in Action): „Certificate of Completion", 14.04.2026, **kein Ablauf**. Claude Code Masterclass (Everlast): gültig 14.04.2026–13.04.2028.
