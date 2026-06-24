# 24.06.2026 — Morgen-Notiz (nach der langen Nacht)

## Stand beim Aufwachen
- **Diktat = verlässlich wortwörtlich.** Standard „Roh", Murmel ändert kein Wort, erfindet nichts. (Vertrauens-Entscheidung der Nacht, Option A.)
- **Voice-Agent aus** (rechte ⌥ inaktiv). Code bleibt, reaktivierbar.
- **Terminal-Vorlese-Hook (Thorsten) entfernt** — sowohl `~/.claude/tts/mute` gesetzt als auch aus `~/.claude/settings.json` entfernt. Endgültig weg nach nächstem Claude-Code-Start.
- **Lokaler Wissens-Index gefüllt:** 1.975 Dateien, **58.009 Chunks**, 0 Fehler (headless via `/tmp/murmel-index`, reuse der echten KnowledgeStore/Indexer-Klassen → schema-identisch). DB: `~/.murmel/knowledge.sqlite`.
- Murmel-App läuft, alle Commits gepusht (github.com/alexheyers/murmel).

## Was das bedeutet
Die **Offline-Wissensgrundlage steht** — der erste echte Stein des Nordsterns („offline + mit allem verbunden"). Murmel *könnte* jetzt aus deinen Projekten antworten — aber der Abfrage-Weg (RAG-Suche → Antwort) ist aktuell nur im (abgeschalteten) Gesprächs-Modus verdrahtet.

## Nächste Schritte (ausgeruht, gestuft)
1. **Index frisch halten:** den headless Indexer als wiederkehrenden Lauf (inkrementell, überspringt Unverändertes). Optional als Skill/Cron.
2. **Abfrage-Weg bauen, den du wirklich willst:** Cursor irgendwo → fn/Kurzbefehl → Murmel sucht im Index (+ später Notion/Gmail) → Antwort am Cursor. Das ist die „frag mein Zeug"-Funktion — sauber, verifiziert, eine Scheibe.
3. **Intent-Frage entscheiden** (fn = immer Diktat + Schlüsselwort für Befehle?).
4. Erst danach: Cloud-Eskalation (Opus) für Mehrquellen-Synthese, weitere Connectoren.

## Lektion der Nacht (kurz)
Daily-value-first, Vertrauen vor Magie, am echten Gerät testen, Sicherheitsnetz vor dem Sprung. Lokales 3B/7B formatiert nicht zuverlässig wortgetreu → deshalb „Roh" als Standard.

— Claude (Opus 4.8)
