# Murmel — Voice-to-Text für macOS (Design-Spec)

**Datum:** 2026-06-21
**Status:** Genehmigt → Implementierung
**Autor:** Alex Heyers (mit Claude)

---

## 1. Zweck

Wispr-Flow-/Voicely-artiges Diktier-Tool für macOS. **fn-Taste halten → sprechen →
loslassen → der erkannte (und KI-polierte) Text wird ins aktive Fenster eingefügt.**
Phase-1-Fokus: Terminal / Claude Code. Architektur offen für „systemweit" (funktioniert
technisch bereits in jeder App, da über Zwischenablage + ⌘V eingefügt wird).

Alles läuft **lokal & offline**: keine laufenden Kosten, volle Privatsphäre.

## 2. Entscheidungen (aus dem Brainstorming)

| Thema | Entscheidung |
|---|---|
| Reichweite | Phase 1 Terminal, Architektur offen für systemweit |
| Speech-to-Text | **Lokal — whisper.cpp** (Modell `large-v3-turbo`, deutsch, Apple-Silicon-schnell) |
| Auslöser | **Push-to-talk: fn-Taste halten** (Fallback: rechte ⌥) |
| Text-Veredelung | **Lokale KI-Politur via Ollama** (kleines Modell, z.B. `qwen2.5:3b`) |
| Form & Feedback | **Menubar-App** (Icon-Status + Start/Stop-Sound) |
| Auto-Start | **Login-Item** („Bei Anmeldung starten") |
| Stack | **Native Swift** (Swift Package Manager, kein volles Xcode nötig) |
| Extras Phase 1 | Eigenes Wörterbuch · Diktat-Verlauf · Stil-Modi · Sprachbefehle |

## 3. Architektur

Eine einzige macOS-Menubar-App (Swift, `MenuBarExtra`). Kein Server. Ruft zwei lokale
Programme als Unterprozesse: `whisper-cli` (Transkription) und `ollama` (Politur, via HTTP).

```
   fn halten ──▶ 🔴 Aufnahme ──▶ loslassen ──▶ ⏳ Verarbeitung ──▶ ✅ ⌘V einfügen
```

### Bausteine (je ein Swift-File, eine Aufgabe)

| Baustein | Datei | Aufgabe |
|---|---|---|
| HotkeyMonitor | `Hotkey/HotkeyMonitor.swift` | CGEventTap auf fn/⌥ — Halten erkennen (down/up) |
| AudioRecorder | `Audio/AudioRecorder.swift` | AVAudioEngine → 16 kHz Mono WAV in temp-Datei |
| Transcriber | `Transcription/Transcriber.swift` | Ruft `whisper-cli` als Process auf → Rohtext |
| Polisher | `Polish/Polisher.swift` | URLSession → Ollama `/api/generate`, Stil-Prompt |
| TextInserter | `Insertion/TextInserter.swift` | NSPasteboard + CGEvent ⌘V ins aktive Fenster |
| Vocabulary | `Features/Vocabulary.swift` | `vokabular.json` laden, Begriffe nachkorrigieren |
| History | `Features/History.swift` | SQLite (libsqlite3) — Diktat-Verlauf speichern/suchen |
| VoiceCommands | `Features/VoiceCommands.swift` | Gesprochene Befehle → Aktionen ("neue Zeile" → \n) |
| Settings | `Settings/Settings.swift` | UserDefaults — Hotkey, Modelle, Stil, Pfade, Login-Item |
| MenuBarView | `UI/MenuBarView.swift` | Menubar-Icon, Status, Verlauf-Menü, Stil-Dropdown |
| AppCoordinator | `Core/AppCoordinator.swift` | Verdrahtet alles, Zustandsmaschine |
| Models/Protocols | `Core/*.swift` | Geteilte Typen + Interface-Verträge |

### Datenfluss (Pipeline beim Loslassen)

1. `AudioRecorder` stoppt → WAV-Datei.
2. `Transcriber` → Rohtext.
3. `VoiceCommands.process` → Befehle ersetzt/ausgeführt.
4. `Vocabulary.correct` → Fachbegriffe gefixt.
5. `Polisher.polish(text, style)` → finaler Text (Fallback: Rohtext, wenn Ollama down).
6. `History.add` → speichern.
7. `TextInserter.insert` → ⌘V ins aktive Fenster.

## 4. Extra-Features (Phase 1)

- **Wörterbuch** — `vokabular.json` (editierbar), z.B. `{"n acht n":"n8n"}`. Wirkt als
  Nachkorrektur **und** als Prompt-Hinweis an den Polisher.
- **Diktat-Verlauf** — lokale SQLite-DB; Felder: id, timestamp, raw, final, style.
  Menubar → „Verlauf" durchsuchbar, „erneut einfügen".
- **Stil-Modi** — Dropdown: `Roh` / `E-Mail` / `Code-Kommentar` / `Claude-Prompt`.
  Je Modus ein Politur-Prompt. Letzter Modus wird gemerkt. `Roh` überspringt Ollama.
- **Sprachbefehle** — Mapping gesprochen→Aktion, **vor** der Politur ausgewertet:
  „neue Zeile" → `\n`, „Punkt" → `.`, „alles löschen" → Diktat verwerfen, „abbrechen".

## 5. Zustände (State Machine)

`idle → recording → transcribing → polishing → inserting → idle`
Fehlerzweige führen immer zurück nach `idle` (Audio wird nie verworfen, bis erfolgreich).

## 6. Rechte & Abhängigkeiten

- **macOS-Rechte (einmalig):** Mikrofon (NSMicrophoneUsageDescription) + Bedienungshilfen
  (für CGEventTap & ⌘V). App führt mit Klartext durch den Permission-Flow.
- **Externe Tools:** `whisper-cli` (brew `whisper-cpp`) + Modell `large-v3-turbo`;
  `ollama` + Modell `qwen2.5:3b`. Installiert/geprüft via `Scripts/setup.sh`.
- **Keine Swift-Package-Dependencies** — nur System-Frameworks (AVFoundation, AppKit,
  CoreGraphics, Foundation, SwiftUI, SQLite3).

## 7. Build & Verteilung

- `swift build -c release` → Binary.
- `Scripts/make-app.sh` verpackt Binary + `Info.plist` → `Murmel.app` (Bundle-ID
  `de.alexheyers.murmel`, damit macOS-Rechte sauber greifen).
- Kopieren nach `/Applications`. „Bei Anmeldung starten"-Schalter (SMAppService).
- Kein App-Store, keine Notarisierung für den eigenen Mac nötig.

## 8. Fehlerbehandlung

- whisper/ollama fehlen → klare Meldung + Hinweis auf `setup.sh`; Audio bleibt erhalten.
- Ollama down → automatischer Fallback auf **Rohtext**.
- Leere/Stille-Aufnahme → leiser Hinweis-Sound, kein Einfügen.
- fn-Konflikt mit macOS → Setup stellt „fn drücken für → Nichts tun" ein; ⌥-Fallback.

## 9. Tests

- **Unit:** Vocabulary-Korrektur, VoiceCommands-Parsing, Polisher-Prompt-Bau, WAV-Header.
- **Manuell (Checkliste):** Permission-Flow, fn-Halten, Aufnahme, Einfügen ins Terminal.

## 10. Spätere Ausbaustufen (nicht Phase 1)

Systemweite App-Erkennung & kontextabhängige Stile · Streaming-Transkription (Text
erscheint beim Sprechen) · Wörterbuch-UI · Statistiken (Wörter/Minute) · Snippets/Textbausteine.
