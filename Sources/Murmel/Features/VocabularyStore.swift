import Foundation

/// Korrigiert Fachbegriffe und Eigennamen anhand eines Wörterbuchs (`vokabular.json`).
///
/// Das Wörterbuch ist eine flache JSON-Map `{ "falschschreibung": "Korrektbegriff", ... }`.
/// Beim Diktieren werden Fachbegriffe von Whisper oft phonetisch falsch erkannt
/// (z.B. "n acht n" statt "n8n"). `correct(_:)` ersetzt solche bekannten Falschschreibungen
/// case-insensitive und an Wortgrenzen durch den korrekten Zielbegriff.
final class VocabularyStore: VocabularyCorrecting {

    // MARK: - Interner Zustand

    /// Map Falschschreibung → Korrektbegriff. Nur über die serielle Queue lesen/schreiben.
    private var dictionary: [String: String] = [:]

    /// Vorkompilierte Ersetzungs-Regeln (eines pro Wörterbuch-Eintrag),
    /// damit `correct(_:)` nicht bei jedem Aufruf neu kompilieren muss.
    private var rules: [(regex: NSRegularExpression, replacement: String)] = []

    /// Serielle Queue sichert den Zugriff auf `dictionary`/`rules` ab.
    /// Reicht völlig für die Aufrufe vom Main-Thread — keine Über-Engineering nötig.
    private let queue = DispatchQueue(label: "de.murmel.vocabularystore")

    // MARK: - Init

    /// Lädt das Wörterbuch direkt beim Erzeugen (legt bei Bedarf eine Default-Datei an).
    init() {
        reload()
    }

    // MARK: - VocabularyCorrecting

    /// Ersetzt jede bekannte Falschschreibung durch den korrekten Zielbegriff.
    /// - Ersetzung erfolgt case-insensitive und nur an Wortgrenzen (`\b…\b`),
    ///   damit Teilworte (z.B. "claude" in "Claudette") nicht zerstört werden.
    func correct(_ text: String) -> String {
        // Snapshot der Regeln unter der Queue holen, dann ausserhalb arbeiten.
        let activeRules = queue.sync { rules }
        guard !activeRules.isEmpty else { return text }

        var result = text
        for rule in activeRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            // Der Zielbegriff wird wörtlich eingesetzt; `$`/`\` im Replacement maskieren,
            // damit NSRegularExpression sie nicht als Template-Referenzen interpretiert.
            let template = NSRegularExpression.escapedTemplate(for: rule.replacement)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result
    }

    /// Die korrekten Zielbegriffe (Values), dedupliziert — als Schreibhilfe für den Polisher.
    var terms: [String] {
        queue.sync {
            // Reihenfolge stabil halten, Duplikate entfernen.
            var seen = Set<String>()
            var unique: [String] = []
            for value in dictionary.values where !seen.contains(value) {
                seen.insert(value)
                unique.append(value)
            }
            return unique.sorted()
        }
    }

    /// Lädt `vokabular.json` neu von der Platte. Existiert keine Datei, wird eine
    /// sinnvolle Default-Datei geschrieben und anschliessend verwendet.
    func reload() {
        queue.sync {
            let loaded = Self.loadOrCreateDefault()
            dictionary = loaded
            rules = Self.compileRules(from: loaded)
        }
    }

    // MARK: - Laden / Default anlegen

    /// Liest das Wörterbuch von der Platte oder legt — falls nicht vorhanden bzw.
    /// nicht lesbar — die Default-Datei an und gibt deren Inhalt zurück.
    private static func loadOrCreateDefault() -> [String: String] {
        let url = MurmelPaths.vocabularyFile
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
                return parsed
            }
            // Datei existiert, ist aber kaputt: Defaults verwenden, ohne sie zu überschreiben.
            return defaultVocabulary
        }

        // Datei fehlt → Defaults schreiben und nutzen.
        writeDefault()
        return defaultVocabulary
    }

    /// Schreibt das Default-Wörterbuch hübsch formatiert nach `MurmelPaths.vocabularyFile`.
    private static func writeDefault() {
        // Sicherstellen, dass ~/.murmel existiert.
        MurmelPaths.ensureDirectories()

        let encoder = JSONEncoder()
        // Pretty-Print + stabile Schlüsselreihenfolge für eine gut lesbare Datei.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(defaultVocabulary) else { return }
        try? data.write(to: MurmelPaths.vocabularyFile, options: .atomic)
    }

    // MARK: - Regeln kompilieren

    /// Baut aus dem Wörterbuch vorkompilierte Wortgrenzen-Regeln.
    /// Sonderzeichen im Schlüssel werden maskiert, damit sie wörtlich gematcht werden.
    private static func compileRules(
        from dictionary: [String: String]
    ) -> [(regex: NSRegularExpression, replacement: String)] {
        var compiled: [(NSRegularExpression, String)] = []

        // Längere Schlüssel zuerst, damit spezifischere Treffer ("n acht n")
        // vor kürzeren ("n") greifen.
        let sortedKeys = dictionary.keys.sorted { $0.count > $1.count }

        for key in sortedKeys {
            guard let replacement = dictionary[key], !key.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            compiled.append((regex, replacement))
        }
        return compiled
    }

    // MARK: - Default-Wörterbuch

    /// Typische Fachbegriffe aus Alex' Stack, die Whisper gern verstümmelt.
    private static let defaultVocabulary: [String: String] = [
        "n acht n": "n8n",
        "n 8 n": "n8n",
        "supabase": "Supabase",
        "super base": "Supabase",
        "cloud code": "Claude Code",
        "claude": "Claude",
        "vercel": "Vercel",
        "github": "GitHub",
        "docker": "Docker",
        "hostinger": "Hostinger",
        "ollama": "Ollama",
        "whisper": "Whisper"
    ]
}
