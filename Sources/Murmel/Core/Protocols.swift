import Foundation

// MARK: - Interface-Verträge
//
// Jede Komponente implementiert genau EIN Protokoll in genau EINER Datei.
// Der AppCoordinator instanziiert die konkreten Klassen und verdrahtet sie.
// Konkrete Klassennamen (Vertrag):
//   AudioRecording        -> AudioRecorder
//   Transcribing          -> WhisperTranscriber
//   Polishing             -> OllamaPolisher
//   TextInserting         -> PasteboardInserter
//   HotkeyMonitoring      -> HotkeyMonitor
//   VocabularyCorrecting  -> VocabularyStore
//   HistoryStoring        -> HistoryStore
//   VoiceCommandProcessing-> VoiceCommandProcessor

/// Nimmt Mikrofon auf, solange aufgenommen wird, und liefert eine WAV-Datei.
protocol AudioRecording: AnyObject {
    /// Startet die Aufnahme (16 kHz, Mono). Wirft bei Engine-Fehlern.
    func startRecording() throws
    /// Stoppt die Aufnahme und liefert die fertige WAV-Datei (oder nil bei Stille/Fehler).
    func stopRecording() -> URL?
    /// Schreibt das bisher Aufgenommene in eine temporäre WAV (für Live-Vorschau),
    /// ohne die laufende Aufnahme zu stoppen. nil, wenn (noch) zu wenig Audio da ist.
    /// - Parameter maxSeconds: >0 → nur das letzte Zeitfenster dieser Länge (gleitendes
    ///   Fenster für schnelle Vorschau bei langen Diktaten); 0 → alles bisher Aufgenommene.
    func snapshotWAV(maxSeconds: Double) -> URL?
}

/// Wandelt eine WAV-Datei in Text (whisper.cpp).
protocol Transcribing: AnyObject {
    /// - Parameters:
    ///   - wav: Pfad zur 16-kHz-Mono-WAV.
    ///   - prompt: optionaler „initial prompt" zum Biasing (Eigennamen/Fachbegriffe,
    ///     damit Whisper sie direkt korrekt erkennt). Leerstring = kein Biasing.
    /// - Returns: erkannter Rohtext (getrimmt).
    func transcribe(_ wav: URL, prompt: String) async throws -> String
}

/// Räumt den Rohtext über ein lokales LLM (Ollama) auf.
/// Wirft NIE — bei Fehlern/Ollama-down wird der Rohtext zurückgegeben (Fallback).
protocol Polishing: AnyObject {
    /// - Parameters:
    ///   - text: Rohtext (nach Sprachbefehlen & Wörterbuch).
    ///   - style: gewählter Stil-Modus (`.raw` → keine Politur, gibt text unverändert zurück).
    ///   - instruction: die (ggf. vom Nutzer angepasste) Stil-Instruktion für das LLM.
    ///   - vocabularyHint: Begriffe aus dem Wörterbuch (als Schreibhilfe in den Prompt).
    func polish(_ text: String, style: DictationStyle, instruction: String, vocabularyHint: [String]) async -> String
}

/// Fügt Text ins aktive Fenster ein (Zwischenablage + ⌘V).
protocol TextInserting: AnyObject {
    func insert(_ text: String)
}

/// Globaler Push-to-talk-Hotkey. Ruft Callbacks bei Drücken/Loslassen.
protocol HotkeyMonitoring: AnyObject {
    /// Wird aufgerufen, wenn die Trigger-Taste gedrückt wird (Beginn Aufnahme).
    var onPress: (() -> Void)? { get set }
    /// Wird aufgerufen, wenn die Trigger-Taste losgelassen wird (Ende Aufnahme).
    var onRelease: (() -> Void)? { get set }
    /// Welche Taste lauschen. Kann zur Laufzeit gewechselt werden.
    var trigger: HotkeyTrigger { get set }
    /// Startet das Event-Tap. Wirft bzw. gibt false, wenn Bedienungshilfen-Recht fehlt.
    func start() -> Bool
    func stop()
}

/// Korrigiert Fachbegriffe/Namen anhand des Wörterbuchs (vokabular.json).
protocol VocabularyCorrecting: AnyObject {
    /// Ersetzt bekannte Falschschreibungen durch korrekte Begriffe (case-insensitive Wortgrenzen).
    func correct(_ text: String) -> String
    /// Die korrekten Zielbegriffe (für den Polisher-Prompt-Hinweis).
    var terms: [String] { get }
    /// Lädt vokabular.json neu von der Platte.
    func reload()
}

/// Persistiert den Diktat-Verlauf (SQLite).
protocol HistoryStoring: AnyObject {
    func add(raw: String, final: String, style: DictationStyle, app: String)
    func recent(limit: Int) -> [HistoryEntry]
    func search(_ query: String) -> [HistoryEntry]
}

// MARK: - RAG / Daten-Assistent
//
// Konkrete Klassen (Vertrag):
//   EmbeddingClient   -> OllamaEmbeddingClient   (Datei Knowledge/OllamaEmbeddingClient.swift)
//   KnowledgeStoring  -> KnowledgeStore          (Datei Knowledge/KnowledgeStore.swift)
//   KnowledgeIndexing -> KnowledgeIndexer        (Datei Knowledge/KnowledgeIndexer.swift)
//   DataAssisting     -> DataAssistant           (Datei Knowledge/DataAssistant.swift)

/// Wandelt Text in einen Embedding-Vektor (lokal via Ollama).
protocol EmbeddingClient: AnyObject {
    /// nil bei Fehler / Ollama nicht erreichbar.
    func embed(_ text: String) async -> [Float]?
}

/// Persistiert Wissens-Chunks samt Vektoren und sucht die ähnlichsten (SQLite).
protocol KnowledgeStoring: AnyObject {
    /// Letzte bekannte mtime eines Pfads (für inkrementelles Indexieren), nil wenn unbekannt.
    func mtime(forPath path: String) -> Double?
    /// Ersetzt ALLE Chunks eines Pfads durch die neuen (delete + insert).
    func replace(path: String, source: String, mtime: Double, chunks: [(text: String, vector: [Float])])
    /// Entfernt Chunks, deren `path` NICHT in `keepPaths` enthalten ist (gelöschte Dateien).
    func prune(keepPaths: Set<String>)
    /// Die k ähnlichsten Chunks zum Query-Vektor (Cosine-Similarity).
    func search(queryVector: [Float], k: Int) -> [RetrievedChunk]
    /// Bekannte Datei-Pfade (source=="file").
    func knownFilePaths() -> Set<String>
    var chunkCount: Int { get }
}

/// Indexiert Ordner + Diktat-Verlauf in den Store (inkrementell).
protocol KnowledgeIndexing: AnyObject {
    func reindex(folders: [String], history: [HistoryEntry]) async -> IndexResult
}

/// Beantwortet/erfüllt eine gesprochene Anweisung per RAG über die eigenen Daten.
protocol DataAssisting: AnyObject {
    func answer(instruction: String, topK: Int) async -> AssistantResult
}

/// Wertet gesprochene Befehle aus, BEVOR poliert wird.
protocol VoiceCommandProcessing: AnyObject {
    /// "neue Zeile" → \n, "punkt" → ., "alles löschen"/"abbrechen" → aborted=true.
    func process(_ text: String) -> VoiceCommandResult
}
