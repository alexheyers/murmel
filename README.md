# 🎙️ Murmel

**Lokales Voice-to-Text für macOS — fn-Taste halten, sprechen, loslassen. Der Text landet im aktiven Fenster.**

![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20·%20Apple%20Silicon-0F1F3D)
![Language](https://img.shields.io/badge/Swift-6.2-F59E0B)
![STT](https://img.shields.io/badge/STT-whisper.cpp-0D9488)
![Polish](https://img.shields.io/badge/Polish-Ollama-0D9488)
![License](https://img.shields.io/badge/License-MIT-475569)

Ein selbstgebautes Wispr-Flow-/Voicely-Pendant. Alles läuft **offline auf deinem Mac**:
keine laufenden Kosten, keine Cloud, volle Privatsphäre.

> **Live-Beweis (echtes Diktat, ein Take, Deutsch + Englisch gemischt):**
> *„Okay, das wird jetzt ein längerer Test für meine neue Murmel-App. Ich möchte ausprobieren, ob das alles so klappt, wie es klappen sollte. Geh mal davon aus, dass wir sowohl prompten als auch colloquial, English as well, you should get everything."*
> → exakt so eingefügt. Code-Switching DE/EN, Zeichensetzung, „Murmel-App" — alles korrekt.

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

## Installation (Download — empfohlen)

> Voraussetzung: macOS 14+ auf **Apple Silicon** und [Homebrew](https://brew.sh).

1. Neueste **`Murmel-x.y.z.dmg`** unter [Releases](https://github.com/alexheyers/murmel/releases) laden, öffnen, **Murmel.app → Programme** ziehen.
2. Die App ist selbst-signiert (kein 99 €/Jahr-Apple-Account) → Gatekeeper einmalig lösen:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Murmel.app
   ```
   (oder Rechtsklick auf die App → **Öffnen** → **Öffnen**)
3. **Murmel starten.** Beim ersten Start öffnet sich die **Ersteinrichtung**: sie lädt
   mit Zwischenfragen automatisch whisper.cpp, die Modelle (large-v3-turbo, VAD) und
   Ollama + Qwen herunter — alles lokal, ~4 GB.
4. Bedienungshilfen-Recht erteilen → **fn halten und sprechen.**

> Die Einrichtung ist jederzeit über das Menüleisten-Icon → **„Einrichtung & Status prüfen"** erreichbar.

---

## Installation (clone & build)

> Voraussetzungen: macOS 14+ auf **Apple Silicon**, [Homebrew](https://brew.sh),
> Swift (Xcode **oder** Command Line Tools: `xcode-select --install`).

```bash
# 0. Holen
git clone https://github.com/alexheyers/murmel.git
cd murmel

# 1. Laufzeit-Abhängigkeiten (idempotent): whisper-cpp + Modell large-v3-turbo
#    (~1,5 GB → ~/.murmel/models/), ollama + Politur-Modell qwen2.5:3b
./Scripts/setup.sh

# 2. Stabile Signatur-Identität anlegen (einmalig) — sorgt dafür, dass die
#    macOS-Rechte über Rebuilds hinweg erhalten bleiben
./Scripts/make-cert.sh

# 3. App bauen & verpacken → dist/Murmel.app
./Scripts/make-app.sh
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

## Wie es gebaut wurde (inkl. Debugging)

Murmel entstand an einem Nachmittag mit Claude Code im Terminal — Gerüst + feste
Protokoll-Verträge zuerst, dann **8 KI-Agents parallel** (je eine Komponente).
Die ehrliche Geschichte inkl. der zwei echten Bugs und ihrer Root-Cause-Analyse:

- **Making-of (HTML):** [`docs/making-of.html`](docs/making-of.html) — visuell, im Bootcamp-Stil
- **Spec:** [`docs/superpowers/specs/2026-06-21-murmel-voice-terminal-design.md`](docs/superpowers/specs/2026-06-21-murmel-voice-terminal-design.md)

Kurz, die zwei Bugs:
1. **Bedienungshilfen-Recht verschwand bei jedem Rebuild.** Root Cause: macOS bindet
   das Recht an die Code-Signatur; Ad-hoc-Signaturen ändern bei jedem Build den Hash.
   Fix: **stabile selbst-signierte Identität** (`Scripts/make-cert.sh`).
2. **Die KI-Politur halluzinierte** (kippte das Wörterbuch in den Text, antwortete wie
   ein Chatbot). Root Cause: zu schwacher Prompt für ein 3B-Modell. Fix: Chat-API +
   strikter System-Prompt + **Halluzinations-Schutz** (zu lange Ausgabe → Fallback auf
   Rohtext) + Standard auf **„Roh"**.

Gefunden wurden beide per **Datei-Logging** (`~/.murmel/murmel.log`) — Evidenz an jeder
Pipeline-Stufe, statt zu raten.

## Roadmap (spätere Ausbaustufen)

- Systemweite App-Erkennung & kontextabhängige Stile
- Streaming-Transkription (Text erscheint beim Sprechen)
- Wörterbuch-UI, Statistiken (Wörter/Minute), Textbausteine
- Notarisierte `.app` für echten Doppelklick-Download (Apple Developer Account nötig)

## Lizenz

MIT — siehe [LICENSE](LICENSE). Nutz es, bau es um, teil es.

---

Gebaut von **Alex Heyers** im Rahmen des Vibe Coding Bootcamps. Lokal, privat, eigenes Werkzeug.
