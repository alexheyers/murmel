import Foundation

/// Räumt den Whisper-Rohtext über ein lokales LLM (Ollama) auf.
///
/// Wichtigste Eigenschaft: `polish(_:style:vocabularyHint:)` wirft NIE.
/// Bei JEDEM Fehler (Ollama nicht erreichbar, Timeout, ungültiges JSON,
/// leere Antwort) wird der ORIGINAL-Text unverändert zurückgegeben.
/// Der Nutzer verliert dadurch niemals ein Diktat — im Zweifel landet
/// einfach die rohe Transkription im Zielfenster.
final class OllamaPolisher: Polishing {

    /// Basis-URL des Ollama-Servers, z. B. "http://127.0.0.1:11434".
    /// Etwaige abschließende Slashes werden beim Init entfernt.
    private let baseURL: String

    /// Name des zu verwendenden Ollama-Modells, z. B. "llama3.2".
    private let model: String

    /// Stärkeres Modell speziell für die Formatierung (Stil „Strukturiert"): zuverlässiger
    /// bei „nur formatieren, nicht antworten/siezen/erfinden" — kostet kaum mehr Zeit.
    /// nil → es wird `model` verwendet.
    private let structuredModel: String?

    /// Eigene URLSession mit knappem Timeout, damit die Politur die
    /// Pipeline nie unangemessen lange blockiert.
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: Adresse des Ollama-Servers (mit/ohne abschließenden Slash).
    ///   - model: Name des Ollama-Modells.
    ///   - structuredModel: optionales, stärkeres Modell nur für die Formatierung.
    init(baseURL: String, model: String, structuredModel: String? = nil) {
        // Abschließende Slashes entfernen, damit wir sauber "/api/generate" anhängen können.
        self.baseURL = baseURL.hasSuffix("/")
            ? String(baseURL.reversed().drop(while: { $0 == "/" }).reversed())
            : baseURL
        self.model = model
        self.structuredModel = structuredModel

        // Knappe Timeouts: lokales LLM darf nicht ewig hängen.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Polishing

    func polish(_ text: String, style: DictationStyle, instruction: String, vocabularyHint: [String]) async -> String {
        // 1) Stil ".raw" → gar nicht polieren, sofort den Rohtext zurückgeben.
        guard style.usesPolish else { return text }

        // 2) Leerer/nur-Whitespace-Text → nichts zu tun.
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return text }

        // 3) Chat-Anfrage senden. JEDER Fehler → Fallback auf den Original-Text.
        do {
            let system: String
            if style.isTranslation, let target = style.targetLanguageName {
                system = buildTranslationPrompt(target: target, nuance: instruction, vocabularyHint: vocabularyHint)
            } else if style.isStructured {
                system = buildStructurePrompt(instruction: instruction, vocabularyHint: vocabularyHint)
            } else if style.isAssistant {
                system = buildAssistantPrompt()
            } else if style.isSummarize {
                system = buildSummarizePrompt()
            } else if style.isCommand {
                // Befehls-Modus: `instruction` ist die gesprochene Anweisung, `text` der Zwischenablage-Inhalt.
                system = buildCommandPrompt(instruction: instruction)
            } else {
                system = buildSystemPrompt(instruction: instruction, vocabularyHint: vocabularyHint)
            }
            // Strukturiert nutzt das stärkere Formatier-Modell (zuverlässiger), Rest das Standard-Modell.
            let useModel = style.isStructured ? (structuredModel ?? model) : model
            let request = try makeChatRequest(model: useModel, system: system, userText: trimmedInput)

            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                Log.line("Polisher: HTTP \(http.statusCode) → Fallback auf Rohtext")
                return text
            }

            guard let polished = parseResponse(data) else {
                Log.line("Polisher: Antwort nicht lesbar → Fallback")
                return text
            }

            let cleaned = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                return text
            }

            // Halluzinations-Schutz nur für Korrektur/Übersetzung — bei Assistent/
            // Zusammenfassen/Befehl variiert die Länge naturgemäß stark.
            if style.usesLengthGuard {
                let limit = max(120, trimmedInput.count * 4)
                if cleaned.count > limit {
                    Log.line("Polisher: Ausgabe zu lang (\(cleaned.count) > \(limit)) → Fallback auf Rohtext")
                    return trimmedInput
                }
            }

            // Wortgetreu-Schutz für „Strukturiert": Die Formatierung MUSS die gesprochenen
            // Wörter behalten. Verliert die Ausgabe die meisten Eingabe-Wörter, hat das Modell
            // GEANTWORTET/umgeschrieben statt zu formatieren → Rohtext zurückgeben.
            // (Lieber unformatiert-aber-wahr als formatiert-aber-erfunden.)
            if style.isStructured,
               Self.wordRetention(input: trimmedInput, output: cleaned) < 0.6 {
                Log.line("Polisher(structured): Wort-Treue zu niedrig → Rohtext (Modell hat geantwortet statt zu formatieren)")
                return trimmedInput
            }

            return cleaned
        } catch {
            return text
        }
    }

    /// Generische Einmal-Anfrage an Ollama (für Features wie Wörterbuch-Vorschläge).
    /// Gibt nil zurück bei jedem Fehler.
    func complete(system: String, user: String) async -> String? {
        do {
            let request = try makeChatRequest(model: model, system: system, userText: user)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return parseResponse(data)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - System-Prompt

    /// Strikter System-Prompt: macht aus dem LLM ein reines Korrektur-Werkzeug,
    /// keinen Chatbot. Verhindert, dass das Modell auf den Inhalt antwortet
    /// oder die Vokabular-Liste in den Text kippt.
    private func buildSystemPrompt(instruction: String, vocabularyHint: [String]) -> String {
        var lines: [String] = [
            "Du bist ein striktes Korrektur-Werkzeug für diktierten Text — KEIN Chatbot.",
            "Du erhältst rohen, per Spracherkennung erzeugten Text. Deine EINZIGE Aufgabe:",
            "gib eine bereinigte Fassung GENAU DIESES Textes zurück (Rechtschreibung,",
            "Zeichensetzung, Groß-/Kleinschreibung).",
            "",
            "Strikte Regeln:",
            "- Antworte NIEMALS auf den Inhalt. Stelle keine Rückfragen. Begrüße nicht.",
            "- Erfinde NICHTS. Füge keine Wörter, Sätze, Listen oder Begriffe hinzu, die nicht vorkommen.",
            "- Behalte die Aussage und ungefähre Länge bei. Kürze den Sinn nicht weg.",
            "- Wenn es nichts zu verbessern gibt, gib den Text unverändert zurück.",
            "- Gib NUR den bereinigten Text aus — ohne Anführungszeichen, ohne Vor- oder Nachwort."
        ]

        let styleInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !styleInstruction.isEmpty {
            lines.append("- Stil: \(styleInstruction)")
        }

        let hints = vocabularyHint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hints.isEmpty {
            lines.append("- Falls (und NUR falls) einer dieser Fachbegriffe im Text vorkommt, schreibe ihn korrekt: "
                         + hints.joined(separator: ", ")
                         + ". Diese Begriffe NIEMALS hinzufügen, wenn sie nicht vorkommen.")
        }

        return lines.joined(separator: "\n")
    }

    /// Struktur-Modus: gliedert langen Fließtext in Absätze, OHNE umzuformulieren.
    /// Bewusst eigener Prompt (nicht der strikte Korrektur-Prompt), weil dieser
    /// Absatz-Umbrüche braucht — der Korrektur-Prompt verbietet Strukturänderungen.
    private func buildStructurePrompt(instruction: String, vocabularyHint: [String]) -> String {
        var lines: [String] = [
            "Du bist ein Formatier-Werkzeug für diktierten Text — KEIN Chatbot, KEIN Autor.",
            "Du machst rohen Sprach-zu-Text gut lesbar — durch FORMAT (Markdown), nicht durch neue Worte.",
            "",
            "GRUNDREGEL: Übernimm JEDES Wort des Roh-Textes in gleicher Reihenfolge. Du fügst nur hinzu:",
            "Satzzeichen, Zeilenumbrüche und Markdown-Zeichen. Du ersetzt/streichst/erfindest KEIN Wort,",
            "keine Synonyme, keine umgestellten Sätze, keine Füllwörter.",
            "",
            "So formatierst du (so viel wie der Inhalt hergibt, sonst nichts):",
            "- AUFZÄHLUNGEN erkennen und als Liste setzen: wenn der Text Dinge nacheinander nennt",
            "  (\"erstens … zweitens …\", \"eins, zwei, drei\", \"Punkt eins …\", oder klar getrennte Punkte),",
            "  schreibe jede als eigene Zeile mit \"- \" (oder \"1. \" \"2. \" bei nummerierter Reihenfolge).",
            "- ABSÄTZE: Leerzeile zwischen verschiedenen Gedanken/Themen.",
            "- **fett** für die zentrale Aussage, *kursiv* für eine Betonung — immer um vorhandene Wörter.",
            "",
            "Strikte Regeln:",
            "- Korrigiere Rechtschreibung, Zeichensetzung, Groß-/Kleinschreibung.",
            "- Behalte Wortwahl, Inhalt und Ton EXAKT bei. Erfinde nichts dazu.",
            "- Behalte die ANREDE GENAU wie gesprochen: du, dein, dich, dir bleiben du, dein, dich, dir.",
            "  Mache daraus NIEMALS Sie, Ihr oder Ihnen. Lockerer Ton bleibt locker, kein Formalisieren.",
            "- Antworte NIEMALS auf den Inhalt, kommentiere nicht, begrüße nicht.",
            "- Sehr kurzer Text (ein, zwei Sätze): nur sauberer Satz, KEINE Liste, kein erzwungenes Format.",
            "- Gib NUR den formatierten Text aus — ohne Code-Fences, ohne Vor- oder Nachwort."
        ]

        let styleInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !styleInstruction.isEmpty {
            lines.append("- Zusätzlich: \(styleInstruction)")
        }

        let hints = vocabularyHint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hints.isEmpty {
            lines.append("- Falls (und NUR falls) einer dieser Fachbegriffe im Text vorkommt, schreibe ihn korrekt: "
                         + hints.joined(separator: ", ") + ".")
        }

        // Beispiel ZULETZT (das Modell ahmt das Letzte am stärksten nach; verhindert Regel-Leak).
        lines.append(contentsOf: [
            "",
            "— BEISPIEL (zeigt nur die Arbeitsweise; übernimm NICHTS von seinem Inhalt) —",
            "ROH: also für morgen drei dinge erstens den entwurf fertig machen zweitens steuer mappe sortieren drittens timo anrufen",
            "FORMATIERT:",
            "Also für morgen drei Dinge:",
            "",
            "1. Den Entwurf fertig machen.",
            "2. Steuer-Mappe sortieren.",
            "3. Timo anrufen."
        ])

        return lines.joined(separator: "\n")
    }

    /// System-Prompt für die Übersetzungs-Modi. Ignoriert die „Sprache beibehalten"-Regel
    /// und übersetzt stattdessen in die Zielsprache.
    private func buildTranslationPrompt(target: String, nuance: String, vocabularyHint: [String]) -> String {
        var lines: [String] = [
            "Du bist ein präziser, muttersprachlicher Übersetzer.",
            "Übersetze den folgenden diktierten Text natürlich und idiomatisch ins \(target).",
            "",
            "Strikte Regeln:",
            "- Gib AUSSCHLIESSLICH die Übersetzung zurück — kein Original, keine Erklärung, keine Anführungszeichen.",
            "- Behalte Sinn, Ton und Eigennamen exakt. Erfinde nichts dazu, lasse nichts weg.",
            "- Antworte NICHT auf den Inhalt — nur übersetzen."
        ]
        let n = nuance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lines.append("- Stil: \(n)") }

        let hints = vocabularyHint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hints.isEmpty {
            lines.append("- Diese Fachbegriffe exakt beibehalten: " + hints.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Assistent-Modus: beantwortet die gesprochene Frage/Anweisung direkt.
    private func buildAssistantPrompt() -> String {
        [
            "Du bist ein hilfreicher, knapper Assistent.",
            "Beantworte die folgende gesprochene Frage oder führe die Anweisung aus — auf Deutsch.",
            "Gib nur die Antwort selbst zurück, ohne Einleitung, ohne Rückfragen, ohne Meta-Kommentar."
        ].joined(separator: "\n")
    }

    /// Zusammenfassen-Modus: fasst das Diktat knapp zusammen.
    private func buildSummarizePrompt() -> String {
        [
            "Fasse den folgenden diktierten Text knapp und klar zusammen.",
            "Nutze Stichpunkte, wenn es mehrere Punkte gibt; sonst zwei, drei Sätze.",
            "Behalte alle wichtigen Aussagen, erfinde nichts dazu.",
            "Gib NUR die Zusammenfassung zurück — ohne Einleitung."
        ].joined(separator: "\n")
    }

    /// Befehls-Modus: wendet die gesprochene Anweisung auf den (Zwischenablage-)Text an.
    private func buildCommandPrompt(instruction: String) -> String {
        let ins = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Du bist ein präzises Text-Werkzeug.",
            "Wende die folgende Anweisung auf den anschließenden Text an:",
            "ANWEISUNG: \(ins)",
            "",
            "Strikte Regeln:",
            "- Gib AUSSCHLIESSLICH den überarbeiteten Text zurück — keine Erklärung, keine Anführungszeichen.",
            "- Antworte NICHT auf den Inhalt, kommentiere nicht — nur die Anweisung ausführen.",
            "- Behalte alles, was die Anweisung nicht betrifft, unverändert."
        ].joined(separator: "\n")
    }

    // MARK: - HTTP-Request (Ollama Chat-API)

    /// Baut den POST-Request an "<baseURL>/api/chat" mit System- und User-Nachricht.
    private func makeChatRequest(model: String, system: String, userText: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/api/chat") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userText]
            ],
            "stream": false,
            "options": ["temperature": 0.1]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        return request
    }

    // MARK: - Antwort-Parsing

    /// Liest den Inhalt aus der Ollama-Chat-Antwort (`message.content`).
    private func parseResponse(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return nil
        }
        return content
    }

    // MARK: - Wortgetreu-Prüfung (reine Logik, testbar)

    /// Anteil der „bedeutsamen" Eingabe-Wörter (≥3 Zeichen), die auch in der Ausgabe
    /// vorkommen. 1.0 = alle behalten, ~0 = komplett umgeschrieben/geantwortet.
    static func wordRetention(input: String, output: String) -> Double {
        let inWords = significantWords(input)
        guard !inWords.isEmpty else { return 1.0 }
        let outSet = Set(significantWords(output))
        let kept = inWords.filter { outSet.contains($0) }.count
        return Double(kept) / Double(inWords.count)
    }

    private static func significantWords(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count >= 3 }
    }
}
