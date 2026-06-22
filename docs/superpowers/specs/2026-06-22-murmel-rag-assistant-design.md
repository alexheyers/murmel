# Murmel Daten-Assistent (lokales RAG) — Design-Spec

**Datum:** 2026-06-22 · **Status:** Genehmigt → Implementierung · **Autor:** Alex Heyers (mit Claude)

## Zweck
Murmel um einen **lokalen RAG-Assistenten** erweitern: Überall per fn-Taste eine Anweisung sprechen
(„recherchiere kurz meine LinkedIn-Strategie und füg sie ein"), Murmel sucht die passenden Stellen in
**Alex' eigenen Daten**, lässt Qwen damit antworten und **fügt das Ergebnis am Cursor ein**.
Alles **100 % lokal & gratis** (Ollama + Qwen + lokales Embedding-Modell).

## Was ist RAG?
**Retrieval-Augmented Generation** = „erst nachschlagen, dann antworten". Statt das Sprachmodell nur aus
seinem Trainingswissen antworten zu lassen, holt man relevante Ausschnitte aus eigenen Daten und gibt sie
dem Modell als Kontext mit. Ergebnis: Antworten, die auf den *eigenen* Inhalten beruhen.

## Modus
Neuer `DictationStyle.dataAssistant` („Daten-Assistent"):
`fn halten → Anweisung sprechen → Retrieval aus eigenen Daten → Qwen erfüllt Auftrag mit Kontext → Einfügen am Cursor`.
Quellen-Transparenz: das Overlay zeigt kurz, *welche* Dateien genutzt wurden; der Text geht ins Dokument.

## Komponenten (isoliert, je 1 Datei — Subagenten-tauglich)
| Baustein | Datei | Aufgabe |
|---|---|---|
| EmbeddingClient | `Knowledge/OllamaEmbeddingClient.swift` | Text → Vektor via Ollama `/api/embeddings` (`nomic-embed-text`) |
| KnowledgeIndex | `Knowledge/KnowledgeIndex.swift` | Ordner durchgehen, Textdateien + Diktat-Verlauf chunken, embedden, in SQLite speichern; inkrementell (mtime) |
| Retriever | `Knowledge/Retriever.swift` | Frage-Vektor → Cosine-Similarity über gespeicherte Vektoren → Top-k Chunks |
| DataAssistant | `Knowledge/DataAssistant.swift` | Orchestriert: retrieve → Prompt bauen → Qwen → Antwort + Quellen |
| Settings/UI | (bestehende erweitern) | Quell-Ordner wählen, Index aktualisieren, Status/Quellen anzeigen |

## Datenmodell (SQLite `~/.murmel/knowledge.sqlite`)
`chunks(id INTEGER PK, source TEXT, path TEXT, mtime REAL, ord INT, text TEXT, vector BLOB)`
- `source`: "file" | "history"; `path`: Datei-Pfad bzw. "history:<id>"; `vector`: Float32-Array als BLOB.

## Indexierung
- Konfigurierbare Ordner (Notizen/Code) → Textdateien (`.md .txt .swift .py .js .ts .html .json …`).
- Diktat-Verlauf (raw) als zusätzliche Quelle.
- Chunking: nach Absätzen, ~Zielgröße 500–800 Zeichen, kleiner Overlap.
- Embedding pro Chunk via `nomic-embed-text`.
- **Inkrementell:** Datei-mtime vergleichen; nur Geändertes neu embedden. Gelöschte Pfade entfernen.

## Retrieval & Antwort
- Frage → Embedding → Cosine-Similarity über alle Chunk-Vektoren (in den Speicher laden) → Top-k (Default 6).
- Prompt (System): „Erfülle die Anweisung des Nutzers AUSSCHLIESSLICH mit dem bereitgestellten Kontext aus
  seinen eigenen Daten. Nenne genutzte Quellen knapp. Wenn der Kontext nichts hergibt, sag das ehrlich.
  Befolge Meta-Wünsche (kurz / Bulletpoints / …). Gib NUR den einzufügenden Text zurück."
- Ausgabe: Text am Cursor (bestehender `PasteboardInserter`); Quellen-Dateinamen im Overlay.

## Settings
`knowledgeFolders: [String]`, `embedModel` (Default `nomic-embed-text`), `topK` (Default 6).

## Setup
`setup.sh` ergänzt: `ollama pull nomic-embed-text` (~270 MB, lokal, gratis).

## Fehlerfälle
Ollama aus → klare Meldung; kein Index/keine Ordner → Hinweis „Ordner wählen + indexieren"; keine Treffer →
ehrlich „in deinen Daten nichts gefunden" (kein Halluzinieren).

## Tests
Unit (ohne Xcode): Chunking-Logik, Cosine-Similarity, Vektor-BLOB-Serialisierung. Rest manuell.

## Phase 2 (später)
Notion als read-only Online-Quelle; Embeddings-Cache-Optimierung; größeres Antwort-Modell on demand.
