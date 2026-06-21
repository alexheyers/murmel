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
    case brainstorm
    case translateEN
    case translateDE
    case command
    case assistant
    case summarize

    var id: String { rawValue }

    /// Anzeigename im Menubar-Dropdown.
    var displayName: String {
        switch self {
        case .raw:          return "Roh"
        case .email:        return "E-Mail"
        case .codeComment:  return "Code-Kommentar"
        case .claudePrompt: return "Claude-Prompt"
        case .brainstorm:   return "Brainstorming"
        case .translateEN:  return "→ Englisch"
        case .translateDE:  return "→ Deutsch"
        case .command:      return "Befehl (Zwischenablage)"
        case .assistant:    return "Assistent"
        case .summarize:    return "Zusammenfassen"
        }
    }

    /// Kurze Beschreibung für die UI.
    var summary: String {
        switch self {
        case .raw:          return "Genau das gesprochene Wort, kein Modell dazwischen."
        case .email:        return "Höflicher, sauberer E-Mail-Fließtext."
        case .codeComment:  return "Knapper, technischer Kommentar- oder Commit-Text."
        case .claudePrompt: return "Klarer, strukturierter Prompt für einen KI-Assistenten."
        case .brainstorm:   return "Lose Gedanken zu klaren Stichpunkten geordnet."
        case .translateEN:  return "Sprich Deutsch — es wird ins Englische übersetzt."
        case .translateDE:  return "Sprich beliebig — es wird ins Deutsche übersetzt."
        case .command:      return "Text kopieren, Anweisung sprechen — wandelt den kopierten Text um."
        case .assistant:    return "Frage stellen — die Antwort wird eingefügt."
        case .summarize:    return "Langes Diktat → knappe Zusammenfassung."
        }
    }

    /// Übersetzungs-Modus? Dann nutzt der Polisher einen Übersetzer-Prompt statt Korrektur.
    var isTranslation: Bool { self == .translateEN || self == .translateDE }
    var isAssistant: Bool { self == .assistant }
    var isSummarize: Bool { self == .summarize }
    /// Befehls-Modus: gesprochene Anweisung wird auf den ZWISCHENABLAGE-Text angewandt.
    var isCommand: Bool { self == .command }
    /// Modi, deren LLM-Eingabe die Zwischenablage ist (statt des Diktats).
    var usesClipboardInput: Bool { self == .command }

    /// Zielsprache bei Übersetzungs-Modi.
    var targetLanguageName: String? {
        switch self {
        case .translateEN: return "Englisch"
        case .translateDE: return "Deutsch"
        default:           return nil
        }
    }

    /// Ob für diesen Stil überhaupt poliert/übersetzt wird.
    var usesPolish: Bool { self != .raw }

    /// Ob für diesen Modus der Halluzinations-Längen-Guard gilt (nur Korrektur/Übersetzung).
    var usesLengthGuard: Bool {
        !(isAssistant || isSummarize || isCommand)
    }

    /// Standard-Instruktion an das lokale LLM (editierbar über die Einstellungen).
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
        case .brainstorm:
            return "Ordne die losen Gedanken zu klaren, knappen Stichpunkten (Bullet-Liste). "
                 + "Behalte jede Idee, erfinde nichts dazu, gruppiere Zusammengehöriges."
        case .translateEN:
            return "Natürliches, idiomatisches Englisch."
        case .translateDE:
            return "Natürliches, idiomatisches Deutsch."
        case .command, .assistant, .summarize:
            return ""
        }
    }

    /// Ob dieser Modus eine editierbare Stil-Instruktion nutzt (für den Modi-Editor).
    var usesEditableInstruction: Bool {
        usesPolish && !isCommand && !isAssistant && !isSummarize
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
    let app: String      // App, in die eingefügt wurde (z.B. "Terminal"), "" wenn unbekannt
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
