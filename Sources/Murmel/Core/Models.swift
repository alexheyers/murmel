import Foundation

/// Zustände der Diktat-Pipeline. Steuert Menubar-Icon und Sounds.
enum AppPhase: Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    case inserting
    case error(String)
}

/// Stil-Modi. Bestimmen, wie der Polisher (Ollama) den Rohtext aufräumt.
/// `.raw` überspringt die Politur komplett (Whisper-Ausgabe wird direkt eingefügt).
enum DictationStyle: String, CaseIterable, Codable, Identifiable {
    case raw
    case email
    case codeComment
    case claudePrompt

    var id: String { rawValue }

    /// Anzeigename im Menubar-Dropdown.
    var displayName: String {
        switch self {
        case .raw:          return "Roh"
        case .email:        return "E-Mail"
        case .codeComment:  return "Code-Kommentar"
        case .claudePrompt: return "Claude-Prompt"
        }
    }

    /// Ob für diesen Stil überhaupt poliert wird.
    var usesPolish: Bool { self != .raw }

    /// Instruktion an das lokale LLM. Wird vom Polisher in den Prompt eingebaut.
    var polishInstruction: String {
        switch self {
        case .raw:
            return ""
        case .email:
            return "Formuliere den Text als sauberen, höflichen E-Mail-Fließtext. "
                 + "Korrekte Rechtschreibung und Zeichensetzung, vollständige Sätze."
        case .codeComment:
            return "Formuliere den Text als prägnanten, technischen Code-Kommentar bzw. "
                 + "Commit-/Doku-Text. Knapp, sachlich, keine Floskeln."
        case .claudePrompt:
            return "Formuliere den Text als klaren, gut strukturierten Prompt/Anweisung an "
                 + "einen KI-Assistenten. Behalte technische Begriffe exakt bei."
        }
    }
}

/// Welche Taste als Push-to-talk dient.
enum HotkeyTrigger: String, CaseIterable, Codable, Identifiable {
    case fn          // fn / 🌐 (Standard)
    case rightOption // rechte ⌥ (Fallback)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn:          return "fn-Taste (🌐)"
        case .rightOption: return "Rechte ⌥-Taste"
        }
    }
}

/// Ein Eintrag im Diktat-Verlauf.
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    let raw: String      // Whisper-Rohtext
    let final: String    // Text der eingefügt wurde
    let style: DictationStyle
}

/// Ergebnis der Sprachbefehl-Auswertung.
struct VoiceCommandResult: Equatable {
    /// Der ggf. transformierte Text (Befehle ersetzt/entfernt).
    let text: String
    /// true → Diktat verwerfen, nichts einfügen ("abbrechen" / "alles löschen").
    let aborted: Bool

    static func passthrough(_ text: String) -> VoiceCommandResult {
        VoiceCommandResult(text: text, aborted: false)
    }
}

/// Fehler innerhalb von Murmel.
enum MurmelError: LocalizedError {
    case whisperBinaryMissing(String)
    case whisperModelMissing(String)
    case transcriptionFailed(String)
    case audioEngineFailed(String)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .whisperBinaryMissing(let p):
            return "whisper-cli nicht gefunden (\(p)). Bitte Scripts/setup.sh ausführen."
        case .whisperModelMissing(let p):
            return "Whisper-Modell nicht gefunden (\(p)). Bitte Scripts/setup.sh ausführen."
        case .transcriptionFailed(let m):
            return "Transkription fehlgeschlagen: \(m)"
        case .audioEngineFailed(let m):
            return "Aufnahme fehlgeschlagen: \(m)"
        case .emptyTranscription:
            return "Keine Sprache erkannt."
        }
    }
}
