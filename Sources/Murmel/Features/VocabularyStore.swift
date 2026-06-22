import Foundation

/// Ein Wörterbuch-Eintrag für die UI: gesprochene Falschschreibung → korrekter Begriff.
struct VocabEntry: Identifiable, Equatable {
    var id: String { wrong }
    let wrong: String   // wie Whisper es (falsch) hört, z.B. "n acht n"
    let right: String   // korrekt, z.B. "n8n"
}

/// Ein KI-Vorschlag fürs Wörterbuch (aus dem Verlauf abgeleitet).
struct VocabSuggestion: Identifiable, Equatable {
    var id: String { wrong + "→" + right }
    let wrong: String
    let right: String
}

/// Korrigiert Fachbegriffe und Eigennamen anhand eines Wörterbuchs (`vokabular.json`).
///
/// Das Wörterbuch ist eine flache JSON-Map `{ "falschschreibung": "Korrektbegriff", ... }`.
/// Beim Diktieren werden Fachbegriffe von Whisper oft phonetisch falsch erkannt
/// (z.B. "n acht n" statt "n8n"). `correct(_:)` ersetzt solche bekannten Falschschreibungen
/// case-insensitive und an Wortgrenzen durch den korrekten Zielbegriff.
///
/// Ist `ObservableObject`, damit die Wörterbuch-UI Änderungen live anzeigt.
final class VocabularyStore: ObservableObject, VocabularyCorrecting {

    /// Für die UI: alle Einträge, alphabetisch nach Falschschreibung. Nur auf Main mutieren.
    @Published private(set) var entries: [VocabEntry] = []

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
        refreshEntries()
    }

    // MARK: - Bearbeiten (aus der UI)

    /// Fügt einen Eintrag hinzu bzw. überschreibt einen bestehenden mit gleichem Schlüssel.
    /// Speichert sofort nach `vokabular.json` und aktualisiert die UI.
    func addEntry(wrong: String, right: String) {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        queue.sync {
            dictionary[w] = r
            rules = Self.compileRules(from: dictionary)
        }
        persistAndRefresh()
    }

    /// Entfernt einen Eintrag, speichert und aktualisiert die UI.
    func removeEntry(_ entry: VocabEntry) {
        queue.sync {
            dictionary[entry.wrong] = nil
            rules = Self.compileRules(from: dictionary)
        }
        persistAndRefresh()
    }

    /// Schreibt das aktuelle Wörterbuch auf die Platte und frischt dann die UI-Liste auf.
    private func persistAndRefresh() {
        let snapshot = queue.sync { dictionary }
        Self.writeDictionary(snapshot)
        refreshEntries()
    }

    /// Baut `entries` (sortiert) aus dem internen Dictionary — immer auf dem Main-Thread.
    private func refreshEntries() {
        let snapshot = queue.sync { dictionary }
        let list = snapshot
            .map { VocabEntry(wrong: $0.key, right: $0.value) }
            .sorted { $0.wrong < $1.wrong }
        if Thread.isMainThread {
            entries = list
        } else {
            DispatchQueue.main.async { self.entries = list }
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
                // Fehlende Default-Einträge einmischen, damit neue Defaults (z.B. „Murmel")
                // auch bestehende Nutzer erreichen — ohne vom Nutzer geänderte/eigene
                // Einträge zu überschreiben.
                var merged = parsed
                var added = false
                for (key, value) in defaultVocabulary where merged[key] == nil {
                    merged[key] = value
                    added = true
                }
                if added { writeDictionary(merged) }
                return merged
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
        writeDictionary(defaultVocabulary)
    }

    /// Schreibt ein beliebiges Wörterbuch hübsch formatiert nach `MurmelPaths.vocabularyFile`.
    private static func writeDictionary(_ dict: [String: String]) {
        // Sicherstellen, dass ~/.murmel existiert.
        MurmelPaths.ensureDirectories()

        let encoder = JSONEncoder()
        // Pretty-Print + stabile Schlüsselreihenfolge für eine gut lesbare Datei.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(dict) else { return }
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
        "whisper": "Whisper",
        // Die App selbst — Whisper verhört „Murmel" gern (z.B. „MoMel").
        "murmel": "Murmel",
        "momel": "Murmel",
        "mömel": "Murmel",
        "mörmel": "Murmel"
    ]
}
