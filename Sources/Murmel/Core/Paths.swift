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
    }
}
