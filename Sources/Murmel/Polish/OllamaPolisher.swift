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

    /// Eigene URLSession mit knappem Timeout, damit die Politur die
    /// Pipeline nie unangemessen lange blockiert.
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: Adresse des Ollama-Servers (mit/ohne abschließenden Slash).
    ///   - model: Name des Ollama-Modells.
    init(baseURL: String, model: String) {
        // Abschließende Slashes entfernen, damit wir sauber "/api/generate" anhängen können.
        self.baseURL = baseURL.hasSuffix("/")
            ? String(baseURL.reversed().drop(while: { $0 == "/" }).reversed())
            : baseURL
        self.model = model

        // Knappe Timeouts: lokales LLM darf nicht ewig hängen.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Polishing

    func polish(_ text: String, style: DictationStyle, vocabularyHint: [String]) async -> String {
        // 1) Stil ".raw" → gar nicht polieren, sofort den Rohtext zurückgeben.
        guard style.usesPolish else { return text }

        // 2) Leerer/nur-Whitespace-Text → nichts zu tun.
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return text }

        // 3) Chat-Anfrage senden. JEDER Fehler → Fallback auf den Original-Text.
        do {
            let system = buildSystemPrompt(style: style, vocabularyHint: vocabularyHint)
            let request = try makeChatRequest(system: system, userText: trimmedInput)

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

            // Halluzinations-Schutz: Ein kleines Modell neigt dazu, zu „antworten"
            // oder Listen anzuhängen. Wird die Politur deutlich länger als das
            // Original, ist das fast sicher Mist → wir nehmen den Rohtext.
            let limit = max(120, trimmedInput.count * 4)
            if cleaned.count > limit {
                Log.line("Polisher: Ausgabe zu lang (\(cleaned.count) > \(limit)) → Fallback auf Rohtext")
                return trimmedInput
            }

            return cleaned
        } catch {
            return text
        }
    }

    // MARK: - System-Prompt

    /// Strikter System-Prompt: macht aus dem LLM ein reines Korrektur-Werkzeug,
    /// keinen Chatbot. Verhindert, dass das Modell auf den Inhalt antwortet
    /// oder die Vokabular-Liste in den Text kippt.
    private func buildSystemPrompt(style: DictationStyle, vocabularyHint: [String]) -> String {
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

        let instruction = style.polishInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            lines.append("- Stil: \(instruction)")
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

    // MARK: - HTTP-Request (Ollama Chat-API)

    /// Baut den POST-Request an "<baseURL>/api/chat" mit System- und User-Nachricht.
    private func makeChatRequest(system: String, userText: String) throws -> URLRequest {
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
}
