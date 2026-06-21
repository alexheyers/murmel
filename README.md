# 🎙️ Murmel

**Lokales Voice-to-Text für macOS — fn-Taste halten, sprechen, loslassen. Der Text landet im aktiven Fenster.**

Ein selbstgebautes Wispr-Flow-/Voicely-Pendant. Alles läuft **offline auf deinem Mac**:
keine laufenden Kosten, keine Cloud, volle Privatsphäre.

```
   fn halten ──▶ 🔴 Aufnahme ──▶ loslassen ──▶ ⏳ Verarbeitung ──▶ ✅ Text eingefügt
```

---

## Was es kann

- **Push-to-talk:** fn-Taste (oder rechte ⌥) halten = Aufnahme, loslassen = einfügen
- **Lokale Spracherkennung** via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Modell `large-v3-turbo`, deutsch, schnell auf Apple Silicon)
- **Lokale KI-Politur** via [Ollama](https://ollama.com) — ähm/äh raus, Satzzeichen, sauberer Stil
- **Stil-Modi:** Roh · E-Mail · Code-Kommentar · Claude-Prompt
- **Eigenes Wörterbuch:** Fachbegriffe korrekt geschrieben (n8n, Supabase, Claude Code …)
- **Diktat-Verlauf:** durchsuchbar (SQLite), Eintrag per Klick erneut einfügen
- **Sprachbefehle:** „neue Zeile", „punkt", „abbrechen" …
- **Menubar-App** mit Status-Icon + dezenten Sounds, **Start bei Anmeldung**

Funktioniert technisch in **jeder** App (Einfügen über Zwischenablage + ⌘V) — Phase-1-Fokus ist das Terminal / Claude Code.

---

## Installation

### 1. Laufzeit-Abhängigkeiten installieren

```bash
./Scripts/setup.sh
```

Installiert (idempotent): `whisper-cpp`, das Whisper-Modell `large-v3-turbo` (~1,5 GB → `~/.murmel/models/`), `ollama` + das Politur-Modell `qwen2.5:3b`.

### 2. App bauen & verpacken

```bash
./Scripts/make-app.sh          # → dist/Murmel.app (ad-hoc signiert)
cp -R dist/Murmel.app /Applications/
open /Applications/Murmel.app
```

### 3. Rechte erteilen (einmalig)

macOS fragt beim ersten Start. Falls nicht:
**Systemeinstellungen → Datenschutz & Sicherheit →**
- **Mikrofon** → Murmel ✓
- **Bedienungshilfen** → Murmel ✓ (nötig für Hotkey-Erkennung & ⌘V-Einfügen)

### 4. fn-Taste freigeben (empfohlen)

**Systemeinstellungen → Tastatur → „fn-/🌐-Taste drücken für" → „Nichts tun"**,
damit macOS dir die fn-Taste nicht wegschnappt. (Alternativ in Murmel auf rechte ⌥ umstellen.)

---

## Benutzung

1. Cursor irgendwohin setzen (Terminal, Editor, Browser …).
2. **fn halten**, sprechen, **loslassen**.
3. Text erscheint. Fertig.

Über das Menubar-Icon: Stil-Modus wählen, Verlauf durchsuchen, Taste umstellen, „Bei Anmeldung starten".

---

## Architektur

Eine Swift-Menubar-App (Swift Package Manager, kein volles Xcode nötig). Saubere Bausteine,
je ein File mit einer Aufgabe — verdrahtet vom `AppCoordinator`.

| Baustein | Datei | Aufgabe |
|---|---|---|
| HotkeyMonitor | `Hotkey/HotkeyMonitor.swift` | Globaler fn/⌥-Halte-Hotkey (CGEventTap) |
| AudioRecorder | `Audio/AudioRecorder.swift` | Mikro → 16 kHz Mono WAV (AVAudioEngine) |
| WhisperTranscriber | `Transcription/WhisperTranscriber.swift` | WAV → Text (`whisper-cli`) |
| OllamaPolisher | `Polish/OllamaPolisher.swift` | Text-Politur (Ollama HTTP), Fallback auf Rohtext |
| PasteboardInserter | `Insertion/PasteboardInserter.swift` | Zwischenablage + ⌘V ins aktive Fenster |
| VocabularyStore | `Features/VocabularyStore.swift` | `vokabular.json`-Korrektur |
| HistoryStore | `Features/HistoryStore.swift` | Diktat-Verlauf (SQLite) |
| VoiceCommandProcessor | `Features/VoiceCommandProcessor.swift` | Sprachbefehle |
| Settings | `Settings/Settings.swift` | Konfiguration (UserDefaults, Login-Item) |
| MenuBarView | `UI/MenuBarView.swift` | Menubar-Panel |
| AppCoordinator | `Core/AppCoordinator.swift` | Verdrahtung + Pipeline-Zustandsmaschine |

Nutzerdaten liegen unter `~/.murmel/` (Modelle, `vokabular.json`, `history.sqlite`, temp. Aufnahmen).

---

## Entwicklung

```bash
swift build            # Debug-Build
swift build -c release # Release-Build
./Scripts/selftest.sh  # Logik-Checks ohne Xcode (Sprachbefehle, Stil, Politur-Fallback)
```

> Die Suite unter `Tests/` nutzt Swift Testing und braucht **volles Xcode**.
> Ohne Xcode verifiziert `selftest.sh` die reine Logik direkt über `swiftc`.

---

## Roadmap (spätere Ausbaustufen)

- Systemweite App-Erkennung & kontextabhängige Stile
- Streaming-Transkription (Text erscheint beim Sprechen)
- Wörterbuch-UI, Statistiken (Wörter/Minute), Textbausteine

---

Gebaut von **Alex Heyers** im Rahmen des Vibe Coding Bootcamps. Lokal, privat, eigenes Werkzeug.
