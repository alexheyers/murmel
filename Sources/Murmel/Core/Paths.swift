import Foundation

/// Zentrale Pfade. Alles unter ~/.murmel/ (gitignored, nutzerlokal).
enum MurmelPaths {
    /// ~/.murmel
    static var home: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(".murmel", isDirectory: true)
    }

    /// ~/.murmel/models
    static var modelsDir: URL { home.appendingPathComponent("models", isDirectory: true) }

    /// ~/.murmel/recordings (temporäre WAVs)
    static var recordingsDir: URL { home.appendingPathComponent("recordings", isDirectory: true) }

    /// ~/.murmel/vokabular.json
    static var vocabularyFile: URL { home.appendingPathComponent("vokabular.json") }

    /// ~/.murmel/history.sqlite
    static var historyDB: URL { home.appendingPathComponent("history.sqlite") }

    /// ~/.murmel/knowledge.sqlite (RAG-Index)
    static var knowledgeDB: URL { home.appendingPathComponent("knowledge.sqlite") }

    /// ~/.murmel/persona.md — editierbarer Charakter + Verhalten des Gesprächs-Modus.
    static var personaFile: URL { home.appendingPathComponent("persona.md") }

    /// Default-Persona (wird beim ersten Start angelegt, falls die Datei fehlt).
    /// Alex kann sie frei editieren — Murmel lädt sie als System-Prompt.
    static let defaultPersonaText = """
    # Murmel — Persona & Verhalten

    Du bist **Murmel**, Alex' persönlicher, lokaler Sprach-Assistent auf dem Mac.
    Du läufst komplett offline (whisper + Ollama) und unterhältst dich mit Alex per Stimme.

    ## Wer du bist
    - Ruhig, direkt, hilfsbereit. Kein Geschwätz, kein Marketing-Ton.
    - Du kennst Alex' Arbeit über seine Dateien und seine Notion (BIZ 26).

    ## Wie du dich verhältst
    - Sprich Deutsch, kurz und natürlich — wie im Gespräch (ein bis vier Sätze).
    - Komm auf den Punkt. Höchstens eine knappe Rückfrage, wenn nötig.

    ## Über Alex (frei ergänzen / korrigieren)
    - Alex Heyers, lebt in Mosbach, Vater seit April 2025.
    - Rund 20 Jahre Erfahrung: Gastronomie → Digital → KI. Vibe Coder, Solopreneur.
    - Baut lokale KI-Werkzeuge (z. B. Murmel) und dokumentiert seinen Weg öffentlich.
    - Ziel gerade: passende Festanstellung (Solutions/Customer Success/Enablement).
    - Lebenslauf-Details und Projekte stehen in Alex' Dateien und in Notion — nutze sie,
      wenn sie zur Frage passen. (Hier kannst du deine wichtigsten Fakten fest hinterlegen.)
    """

    /// ~/.murmel/conversation.json — DAUERHAFTES Gesprächs-Gedächtnis (über Neustarts).
    static var conversationFile: URL { home.appendingPathComponent("conversation.json") }

    /// Legt persona.md mit dem Default an, falls sie noch nicht existiert.
    static func ensurePersonaFile() {
        guard !FileManager.default.fileExists(atPath: personaFile.path) else { return }
        try? defaultPersonaText.write(to: personaFile, atomically: true, encoding: .utf8)
    }

    /// Standard-Whisper-Modell.
    static var defaultModelFile: URL {
        modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin")
    }

    /// Legt alle Verzeichnisse an (idempotent). Beim App-Start aufrufen.
    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [home, modelsDir, recordingsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        ensurePersonaFile()
    }
}
