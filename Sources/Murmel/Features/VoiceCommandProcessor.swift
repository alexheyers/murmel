import Foundation

/// Wertet gesprochene Steuer-Befehle im Whisper-Rohtext aus, BEVOR poliert wird.
///
/// Zwei Klassen von Befehlen:
///   1. Abbruch-Befehle  ("abbrechen", "alles löschen", "vergiss das", "nicht einfügen")
///      → das gesamte Diktat wird verworfen (`aborted == true`).
///   2. Ersetzungs-Befehle (gesprochene Satzzeichen / Layout)
///      → die Phrase wird durch das entsprechende Zeichen bzw. den Umbruch ersetzt.
///
/// EHRLICHE EINSCHRÄNKUNG (Phase-1-Heuristik, bewusst so):
/// Diese Implementierung kennt KEINEN Kontext. Sagt jemand inhaltlich „punkt",
/// „komma", „neue Zeile" usw., wird das IMMER als Befehl interpretiert und durch
/// das Zeichen ersetzt — es gibt keine Unterscheidung zwischen „setze einen Punkt"
/// und dem Wort „Punkt" als Vokabel. Das ist eine akzeptierte Schwäche der ersten
/// Ausbaustufe; echtes Kontextverständnis wäre erst mit LLM-gestützter Auswertung
/// (z.B. im Polisher) sinnvoll.
final class VoiceCommandProcessor: VoiceCommandProcessing {

    // MARK: - Befehls-Tabellen

    /// Phrasen, die das komplette Diktat verwerfen.
    /// Reihenfolge egal — es genügt, wenn EINE davon im Text vorkommt.
    private let abortPhrases: [String] = [
        "abbrechen",
        "alles löschen",
        "vergiss das",
        "nicht einfügen"
    ]

    /// Ersetzungs-Regeln: gesprochene Phrase → einzufügendes Zeichen / Layout.
    /// Reihenfolge ist relevant: längere/mehrteilige Phrasen MÜSSEN vor kürzeren
    /// stehen, damit z.B. „neuer satz" nicht vorzeitig von „satz"/„punkt"-Logik
    /// zerlegt wird. (Tuple-Array statt Dictionary, weil Dictionary keine
    /// definierte Reihenfolge garantiert.)
    private let replacements: [(phrase: String, replacement: String)] = [
        // Layout / Umbrüche (mehrwortig zuerst)
        ("neuer absatz", "\n"),
        ("neue zeile", "\n"),
        ("zeilenumbruch", "\n"),
        ("neuer satz", ". "),
        // Einzelne Satzzeichen
        ("fragezeichen", "?"),
        ("ausrufezeichen", "!"),
        ("doppelpunkt", ":"),
        ("semikolon", ";"),
        ("bindestrich", "-"),
        ("punkt", "."),
        ("komma", ","),
        // Slash als Command-Zeichen (Terminal / Claude-Code-Befehle). Bare „slash"
        // ohne folgendes Wort → „/". „slash <wort>" wird vorher in applySlashCommands
        // zu „/<wort>" zusammengezogen, hier bleibt also nur der Einzelfall.
        ("schrägstrich", "/"),
        ("slash", "/")
    ]

    /// Bekannte Claude-Code-Slash-Befehle + häufige deutsche Verhörer → kanonischer
    /// (englischer, klein geschriebener) Befehl. Wird NUR direkt hinter „slash"/
    /// „schrägstrich" angewandt — dort ist der Kontext eindeutig ein Befehl, das
    /// Zuordnen ist also sicher (z.B. ist „/klar" zweifelsfrei „/clear" gemeint).
    private let slashAliases: [String: String] = [
        "kontext": "context",
        "klar": "clear",
        "kompakt": "compact",
        "modell": "model",
        "hilfe": "help",
        "kosten": "cost",
        "konfig": "config",
        "konfiguration": "config",
        "fortsetzen": "resume",
        "fortsetzung": "resume",
        "rückgängig": "undo",
        "wiederholen": "redo",
        "überprüfen": "review",
        "überprüfung": "review",
        "sicherheit": "security-review"
    ]

    // MARK: - Init

    init() {}

    // MARK: - VoiceCommandProcessing

    func process(_ text: String) -> VoiceCommandResult {
        // 1. Abbruch hat Vorrang vor allem anderen: Sobald eine Abbruch-Phrase
        //    als eigenständiges Wort vorkommt, wird nichts eingefügt.
        for phrase in abortPhrases {
            if containsPhrase(phrase, in: text) {
                return VoiceCommandResult(text: "", aborted: true)
            }
        }

        // 2. Slash-Befehle zuerst: „slash context" → „/context" (Command-Zeichen,
        //    kleingeschrieben, ohne Leerzeichen angehängt).
        var result = applySlashCommands(text)

        // 3. Ersetzungs-Befehle (Satzzeichen / Layout / bare slash) anwenden.
        for rule in replacements {
            result = replacePhrase(rule.phrase, with: rule.replacement, in: result)
        }

        // 4. Wenn sich nichts geändert hat, war kein Befehl enthalten → Passthrough.
        if result == text {
            return .passthrough(text)
        }

        // 5. Aufräumen: Leerzeichen vor Satzzeichen entfernen, Mehrfach-Leerzeichen
        //    zusammenfassen, Umbrüche säubern, dann trimmen.
        result = tidyUp(result)

        return VoiceCommandResult(text: result, aborted: false)
    }

    // MARK: - Slash-Befehle

    /// Wandelt gesprochene Slash-Befehle in echte Commands: „slash context" → „/context".
    /// Das Befehlswort wird kleingeschrieben (Commands sind lowercase) und direkt an
    /// „/" gehängt (kein Leerzeichen), damit z.B. Claude Code es als Befehl erkennt.
    /// Häufige deutsche Verhörer werden über `slashAliases` auf den richtigen Befehl
    /// gemappt. Unbekannte Wörter bleiben erhalten (eigene/Custom-Commands funktionieren also auch).
    private func applySlashCommands(_ text: String) -> String {
        // „slash"/„schrägstrich" + folgendes Wort (Buchstaben/Ziffern/Bindestrich).
        guard let regex = try? NSRegularExpression(
            pattern: "\\b(?:slash|schrägstrich)\\s+([\\p{L}\\p{N}-]+)",
            options: [.caseInsensitive]
        ) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        // Von hinten nach vorne ersetzen, damit die (aus dem Originaltext stammenden)
        // Ranges der früheren Treffer gültig bleiben.
        var result = text
        for match in matches.reversed() {
            let raw = ns.substring(with: match.range(at: 1)).lowercased()
            let command = slashAliases[raw] ?? raw
            result = (result as NSString).replacingCharacters(in: match.range, with: "/" + command)
        }
        return result
    }

    // MARK: - Regex-Helfer

    /// Prüft, ob `phrase` als eigenständige Wortfolge (an Wortgrenzen,
    /// case-insensitive) im Text vorkommt.
    private func containsPhrase(_ phrase: String, in text: String) -> Bool {
        guard let regex = makeRegex(for: phrase) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Ersetzt alle Vorkommen von `phrase` (an Wortgrenzen, case-insensitive)
    /// durch `replacement`.
    private func replacePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        guard let regex = makeRegex(for: phrase) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Ersatztext literal einsetzen: $-Zeichen im Replacement maskieren,
        // damit NSRegularExpression sie nicht als Template-Referenz deutet.
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Baut eine case-insensitive Regex für `phrase`:
    ///   - Regex-Sonderzeichen werden escaped.
    ///   - Leerzeichen in mehrwortigen Phrasen werden zu `\s+` (flexible
    ///     Whitespace-Erkennung, falls Whisper z.B. mehrere Leerzeichen liefert).
    ///   - eingerahmt in `\b…\b`, damit nur ganze Wörter treffen.
    private func makeRegex(for phrase: String) -> NSRegularExpression? {
        // Phrase in Wörter zerlegen und jedes einzeln escapen, damit z.B. ein
        // Bindestrich oder Punkt in einer (hypothetischen) Phrase nicht als
        // Regex-Metazeichen wirkt.
        let words = phrase
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }

        guard !words.isEmpty else { return nil }

        // Wörter mit flexiblem Whitespace verbinden, dann mit Wortgrenzen umschließen.
        let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"

        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: - Aufräumen

    /// Bereinigt typische Artefakte nach den Ersetzungen:
    ///   - Leerzeichen VOR Satzzeichen entfernen ("Hallo ." → "Hallo.").
    ///   - Mehrfach-Leerzeichen auf eines reduzieren.
    ///   - Leerzeichen rund um Zeilenumbrüche entfernen.
    ///   - Ergebnis am Anfang/Ende trimmen.
    private func tidyUp(_ text: String) -> String {
        var result = text

        // Leerzeichen vor Satzzeichen (. , ? ! : ;) tilgen.
        result = regexReplace(in: result, pattern: "[ \\t]+([.,?!:;])", template: "$1")

        // Leerzeichen/Tabs rund um Zeilenumbrüche entfernen.
        result = regexReplace(in: result, pattern: "[ \\t]*\\n[ \\t]*", template: "\n")

        // Mehrfach-Leerzeichen/Tabs auf ein Leerzeichen reduzieren.
        result = regexReplace(in: result, pattern: "[ \\t]{2,}", template: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kleiner Regex-Replace-Helfer für die Aufräum-Schritte.
    private func regexReplace(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
