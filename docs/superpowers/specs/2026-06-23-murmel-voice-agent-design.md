# Murmel → holistischer, lokaler Voice-Agent

> **Design-Dokument · Stand 2026-06-23**
> Vision, Architektur und erste End-to-End-Scheibe. Ausgangspunkt: Murmel ist
> heute lokales Voice-to-Text. Ziel: ein über die **fn-Taste** systemweit
> erreichbarer Assistent, der nicht nur tippt, sondern **den Mac steuert,
> Informationen liefert und Aktionen auslöst** — lokal & kostenlos als Standard,
> Cloud nur an der Spitze.

---

## 1. Vision (in einem Satz)

> *fn halten → sprechen → Murmel versteht, ob du **diktierst, fragst oder befiehlst**,
> und handelt entsprechend: Text einfügen, aus deinen Daten/dem Web antworten,
> oder eine Aktion am Rechner ausführen — überall, ohne die Hände von der Arbeit zu nehmen.*

## 2. Leitprinzipien (nicht verhandelbar)

1. **Lokal & kostenlos als Standard.** 0 € laufende Kosten. Cloud ist Opt-in, nur für Spitzen.
2. **Gestufte Eskalation — „so wenig wie möglich, so viel wie nötig, Vollgas nur an der Spitze".**
   Jede Anfrage nimmt die billigste Stufe, die sie lösen kann. Ressourcen werden
   *on-demand* geladen und nach Leerlauf wieder freigegeben (kritisch bei 16 GB RAM).
   **Vollauslastung ist an die fn-Taste gekoppelt:** zwischen Anfragen ist Murmel
   nahezu im Leerlauf. Das schwere Modell wird bei fn-Druck geladen und nach kurzem
   Leerlauf (`keep_alive`) wieder entladen — kein Dauer-Speicherfresser.
3. **Wortgetreu, wo es um den Nutzer-Text geht.** Beim Diktieren/Formatieren wird
   nichts umgeschrieben — Murmel erfindet keine Inhalte. (Entscheidung 23.06.)
4. **Sicherheit vor Bequemlichkeit.** Kritische/destruktive Aktionen brauchen
   Bestätigung. Allowlist statt Blanko-Vollmacht.
5. **Privatsphäre.** Daten bleiben lokal, solange der Nutzer nicht explizit Cloud zulässt.
6. **Build-in-Public.** Jeder Schritt wird in **Notion** + einer **Making-of-HTML**
   dokumentiert (LinkedIn-verwertbar).

## 3. Hardware-Realität (bestimmt das Machbare)

- **MacBook Pro · Apple M1 Pro · 16 GB** Unified Memory.
- Verfügbar für Modelle real ~8–10 GB (macOS + Apps belegen den Rest).
- **qwen2.5:7B** (~4,7 GB, Q4) → komfortabel neben whisper, gutes Tool-Calling. **Default-Modell.**
- **qwen2.5:14B** (~9 GB) → möglich, aber eng/langsam (whisper braucht ~1,5 GB). Nur als Opt-in-Spitze.
- **Claude (Cloud)** → Hybrid-Eskalation für die wirklich harten Fälle.

## 4. Was heute schon existiert (das Fundament)

| Schicht | Baustein | Datei |
|---|---|---|
| 👂 Hören (STT) | whisper.cpp large-v3-turbo + base-Server (Vorschau) | `Transcription/` |
| 🧠 Denken | Ollama-Politur (Stil-Modi) | `Polish/OllamaPolisher.swift` |
| 🧠 Routen (Heuristik) | Sprachbefehle (Satzzeichen, Slash, Abbruch) | `Features/VoiceCommandProcessor.swift` |
| 📚 Daten (RAG) | Embeddings über Dateien + Verlauf | `Knowledge/` (`DataAssistant`, `KnowledgeStore`) |
| ✋ Handeln | Text einfügen, Zwischenablage-Befehl | `Insertion/PasteboardInserter.swift` |
| 🗣️ Antworten (TTS) | AVSpeechSynthesizer de-DE | `Features/Speaker.swift` |
| 🎯 App-Kontext | aktive App → Stil (Auto-Modus) | `Features/AppStyleMapper.swift` |

**Die Lücke:** Murmel *gibt nur Text aus*. Es hat keinen Intent-Router (diktieren
vs. fragen vs. befehlen) und keine Aktions-Schicht (Apps/System/Automationen/Web).

## 5. Zielarchitektur (5 Bausteine)

```
        ┌─────────────────────── fn gedrückt halten ───────────────────────┐
        │                                                                    │
   [👂 whisper] → roher Text → [① Intent-Router] ──┬── diktieren → [Politur/Format] → einfügen
                                                    │
                                                    ├── fragen   → [③ Daten/Web] → antworten (Text/Stimme)
                                                    │
                                                    └── befehlen → [④ Agent-Loop + ② Tools] → handeln
                                                                          │
                                                                   [⑤ Sicherheit: Bestätigung]
```

### ① Intent-Router (der Kern, neu)
Klassifiziert den Rohtext in **diktieren / fragen / befehlen** (+ bestehende Stil-Modi).
Gestuft: erst Heuristik (Stufe 0), dann kleines LLM (Stufe 1) nur wenn nötig.
Manuelle Stilwahl bleibt immer Vorrang (wie heute beim Auto-Modus).

### ② Aktions-/Tool-Schicht (die „Hände", neu)
Eine Registry typisierter Werkzeuge mit klarem Schema (Name, Beschreibung, Parameter,
`requiresConfirmation`). Jedes Tool ist isoliert testbar. Start klein, wächst additiv:
- **Mac:** App öffnen/wechseln, System (Lautstärke/Helligkeit/Dark Mode), Datei/Ordner öffnen/suchen — via AppleScript/`osascript`/Shortcuts/Shell.
- **Daten:** RAG-Antwort (vorhanden), später Mail/Kalender/Notizen.
- **Automationen (Arm B):** n8n-Webhooks auslösen — hebelt das bestehende System.
- **Web (Hybrid):** Suche/Abruf für aktuelle Fakten.

### ③ Daten-/Kontext-Schicht (die „Sinne")
RAG (vorhanden) + **Live-Kontext**: aktive App, fokussiertes Textfeld?, markierter Text,
Zwischenablage. Der Live-Kontext speist sowohl Router als auch Antworten.

### ④ Agent-Loop + Modell
Ollama-Tool-Calling: Modell bekommt die Tool-Schemata, wählt + ruft Tools, verarbeitet
Ergebnisse, ggf. mehrstufig. **Gestufte Modellwahl** (siehe §2/§3). Cloud-Eskalation als Tool.

### ⑤ Sicherheit
`requiresConfirmation` pro Tool → Murmel fragt vor Ausführung (Stimme/HUD) zurück.
Allowlist für Shell/Apps. Dry-run-Vorschau bei destruktiven Aktionen. Kein blindes `rm`.

## 6. Sprach-Ausgabe — wann antwortet Murmel mit Stimme?

Intent-gesteuert, nicht nur per Schalter:

- **Spricht:** bei *fragen/befehlen* ohne fokussiertes Textfeld; kurze Aktions-Bestätigungen; Hands-free.
- **Spricht nicht (fügt ein):** beim *Diktieren/Formatieren*; bei langen/strukturierten Ergebnissen; globaler Mute.
- **Regel:** *Diktieren → einfügen. Fragen/Befehlen → antworten (Stimme + optional einfügen).*
  Plus Kontext-Check „Textfeld fokussiert?" (Accessibility) und globaler Stumm-Schalter.

Voller **Hands-free-Dialog** (sprechen ↔ sprechen ohne Tippen) = spätere Scheibe (YAGNI für Beweis).

## 7. Hybrid-Strategie

- **Arm A (Kern):** Agent-Loop *in* Murmel, lokal mit qwen2.5:7B + Tool-Calling.
- **Arm B (Automation/Cloud):** schwere/Workflow-Fälle an **n8n** (VPS) — kann bereits LLMs/Tools — und/oder Claude. Murmel ist dann dünner Client.
- Eskalation entscheidet der Router/Loop nach Schwierigkeit + Nutzer-Opt-in.

## 8. Erste End-to-End-Scheibe (der Beweis)

**Ziel:** Die ganze Schleife einmal beweisen — *fn → verstehen → handeln ODER antworten → vorlesen/einfügen.*

**Umfang (Increment 1):**
- **Intent-Router** für 3 Intents: `diktieren` (= bestehende Stil-Pipeline), `fragen` (= RAG-Antwort), `befehlen` (= Tool-Aufruf). Stufe-0-Heuristik + Stufe-1-LLM-Fallback.
- **3 Werkzeuge** mit Schema + Bestätigung:
  1. `App öffnen/wechseln`
  2. `System steuern` (Lautstärke / Dark Mode)
  3. `Aus meinen Daten antworten` (RAG, vorhanden — als Tool gekapselt)
- **qwen2.5:7B** als Agent-Modell (on-demand laden), 3B bleibt für schnelle Politur.
- **Intent-gesteuerte Sprach-Ausgabe** (§6).
- **Bestätigung vor Ausführung** für Tools mit `requiresConfirmation`.
- Eigener **„Agent"-Modus** im Menü (manuell wählbar), Auto-Routing folgt später.

**Nicht in Increment 1 (spätere Scheiben):** n8n-Tools, Web-Tool, Datei-Schreiben,
Hands-free-Dialog, reiches app-bewusstes Formatieren des Strukturiert-Modus (braucht 7B),
14B/Claude-Eskalation, Live-Screen-Kontext.

## 9. Testbarkeit

- Reine Logik (Router-Klassifikation, Tool-Schema-Parsing, Confirmation-Gating) →
  `Scripts/selftest.sh` (swiftc ohne Xcode), Muster wie bestehende Checks.
- Tool-Ausführung gegen Fakes/Mocks (Protokolle wie `Polishing`/`DataAssisting`).
- Agent-Loop mit gestubbtem Ollama-`complete`/Tool-Call (kein Netz nötig).

## 10. Dokumentation (Pflicht-Deliverable)

- **Notion:** Seite unter „Vibe Coding Bootcamp" — Vision, Entscheidungen, Architektur, Fortschritt.
- **Making-of-HTML:** wächst pro Scheibe mit (Editorial-Stil wie `docs/making-of.html`), LinkedIn-verwertbar.

## 11. Offene Entscheidungen / Risiken (ehrlich)

- **Modell-Tempo auf 16 GB:** 7B-Tool-Calling-Latenz real messen — evtl. fühlt sich >2 s träge an. Mitigation: Stufe-0-Heuristik fängt die häufigsten Fälle ohne LLM ab.
- **Tool-Calling-Qualität von qwen2.5:7B:** muss verifiziert werden (3B war zu schwach). Erster Schritt von Increment 1.
- **Sicherheit Shell/Apps:** Allowlist-Design muss stehen, bevor Shell-Tools dazukommen.
- **„Informationen überall":** rein lokal = begrenzt auf Eigendaten + Modellwissen; echtes „frag alles" braucht das Web-Tool (spätere Scheibe).

## 12. Entscheidungs-Log

- **2026-06-23:** Info-Quelle = **Hybrid** (lokal Standard, Cloud optional an der Spitze).
- **2026-06-23:** Strukturiert-Modus = **wortgetreu** (Rhetorik durch Typografie, kein Umschreiben).
- **2026-06-23:** Default-Agent-Modell = **qwen2.5:7B** (M1 Pro/16 GB); 14B/Claude nur Spitze.
- **2026-06-23:** Erste Scheibe = **Agent-Modus mit Intent-Router + 3 Werkzeugen + Bestätigung.**
- **2026-06-23:** Sprach-Ausgabe = **intent-gesteuert**; Hands-free-Dialog später.
- **2026-06-23:** Stimme = **Piper / Thorsten** (neuronal, lokal, gratis) — Wahl gegen Cloud/ElevenLabs.
- **2026-06-23:** **Gesprächs-Modus auf rechter ⌥** gebaut (Push-to-talk: halten → sprechen → gesprochene Antwort).

## 13. Heute umgesetzt (2026-06-23)

1. **Modus „Strukturiert"** (Commit `c253708`) — gliedert Diktat in Absätze, Messenger-Auto-Routing.
2. **Spec** (dieses Dokument) + Piper/Thorsten lokal installiert (`~/.claude/tts`).
3. **Terminal-Stimme** — Claude-Code Stop-Hook liest Antworten mit Thorsten vor (Mute: `~/.claude/tts/mute`).
4. **Gesprächs-Modus** (Commit `831652b`) — rechte ⌥ halten → sprechen → Thorsten antwortet. `ConversationEngine` (Ollama-Chat + Verlauf, 7B→3B-Fallback) + `PiperSpeaker`. Build + Selbsttest grün, live verifiziert.

## 14. Nächste Scheibe — Hands-free-Session (Lang-Druck ⌥)

Statt Push-to-talk: **⌥ länger als ~3 s halten → Thorsten begrüßt → freihändiger Dialog**
(sprechen ↔ antworten ohne Tastenhalten), bis Sitzungsende (erneuter Druck / „Tschüss").
Braucht **Sprechpausen-Erkennung (VAD/Silence-Detection)** für das Turn-Taking — der
eigentliche Mehraufwand. Baut auf `ConversationEngine`/`PiperSpeaker` auf.
