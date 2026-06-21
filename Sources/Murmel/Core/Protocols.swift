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
    func snapshotWAV() -> URL?
}

/// Wandelt eine WAV-Datei in Text (whisper.cpp).
protocol Transcribing: AnyObject {
    /// - Parameter wav: Pfad zur 16-kHz-Mono-WAV.
    /// - Returns: erkannter Rohtext (getrimmt).
    func transcribe(_ wav: URL) async throws -> String
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

/// Wertet gesprochene Befehle aus, BEVOR poliert wird.
protocol VoiceCommandProcessing: AnyObject {
    /// "neue Zeile" → \n, "punkt" → ., "alles löschen"/"abbrechen" → aborted=true.
    func process(_ text: String) -> VoiceCommandResult
}
