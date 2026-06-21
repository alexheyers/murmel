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
        //    Kein Netzwerkaufruf, keine Latenz.
        guard style.usesPolish else { return text }

        // 2) Leerer/nur-Whitespace-Text → nichts zu tun.
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return text }

        // 3) Prompt bauen und Anfrage senden. JEDER Fehler → Fallback auf den Original-Text.
        do {
            let prompt = buildPrompt(text: text, style: style, vocabularyHint: vocabularyHint)
            let request = try makeRequest(prompt: prompt)

            let (data, response) = try await session.data(for: request)

            // HTTP-Status prüfen (z. B. 404 falsches Modell, 500 Server-Fehler) → Fallback.
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return text
            }

            // Antwort parsen und das Feld "response" extrahieren.
            guard let polished = parseResponse(data) else { return text }

            // Ergebnis trimmen; bei leerem Ergebnis Fallback auf Original.
            let cleaned = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned
        } catch {
            // Netzwerkfehler, Timeout, Cancel, JSON-Fehler — egal was: Original zurück.
            return text
        }
    }

    // MARK: - Prompt-Aufbau

    /// Setzt den vollständigen Prompt aus Stil-Instruktion, festen Regeln,
    /// optionalem Vokabular-Hinweis und dem zu überarbeitenden Text zusammen.
    private func buildPrompt(text: String, style: DictationStyle, vocabularyHint: [String]) -> String {
        var parts: [String] = []

        // a) Stil-spezifische Instruktion (z. B. "Formuliere als E-Mail …").
        let instruction = style.polishInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            parts.append(instruction)
        }

        // b) Feste Ausgabe-Regel, damit das Modell NUR den überarbeiteten Text liefert.
        parts.append("Gib AUSSCHLIESSLICH den überarbeiteten Text zurück, ohne Einleitung, ohne Anführungszeichen, ohne Erklärungen.")

        // c) Optionaler Vokabular-Hinweis: Fachbegriffe exakt so schreiben.
        let hints = vocabularyHint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hints.isEmpty {
            parts.append("Schreibe folgende Fachbegriffe exakt so: \(hints.joined(separator: ", ")).")
        }

        // d) Der eigentliche zu überarbeitende Text, klar abgesetzt.
        parts.append("")
        parts.append("Text:")
        parts.append(text)

        return parts.joined(separator: "\n")
    }

    // MARK: - HTTP-Request

    /// Baut den POST-Request an "<baseURL>/api/generate" mit JSON-Body.
    private func makeRequest(prompt: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/api/generate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        // Ollama-Body: kein Streaming, niedrige Temperatur für stabile Politur.
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.2]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        return request
    }

    // MARK: - Antwort-Parsing

    /// Liest robust das Feld "response" (String) aus der Ollama-Antwort.
    /// Gibt nil zurück, wenn das JSON nicht passt oder "response" fehlt.
    private func parseResponse(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = json["response"] as? String
        else {
            return nil
        }
        return response
    }
}
