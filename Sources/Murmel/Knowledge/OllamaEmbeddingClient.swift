import Foundation

/// Erzeugt Embedding-Vektoren lokal via Ollama (`/api/embeddings`).
/// Bei jedem Fehler wird `nil` zurückgegeben — wirft niemals.
final class OllamaEmbeddingClient: EmbeddingClient {

    /// Basis-URL der Ollama-Instanz, ohne abschließende Slashes.
    private let baseURL: String
    /// Embedding-Modell, z.B. "nomic-embed-text".
    private let model: String

    /// - Parameters:
    ///   - baseURL: z.B. "http://127.0.0.1:11434" (abschließende Slashes werden entfernt).
    ///   - model: z.B. "nomic-embed-text".
    init(baseURL: String, model: String) {
        // Abschließende Slashes entfernen, damit der Pfad sauber angehängt werden kann.
        var cleaned = baseURL
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        self.baseURL = cleaned
        self.model = model
    }

    /// Wandelt `text` in einen Embedding-Vektor. nil bei Fehler / Ollama nicht erreichbar.
    func embed(_ text: String) async -> [Float]? {
        // Leerer/whitespace-only Text -> nil (kein sinnvolles Embedding).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ziel-URL bauen.
        guard let url = URL(string: baseURL + "/api/embeddings") else { return nil }

        // JSON-Body { "model": ..., "prompt": ... } robust serialisieren.
        let payload: [String: Any] = ["model": model, "prompt": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        // Request konfigurieren (POST, JSON, ~30s Timeout).
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        // Netzwerk-Aufruf — jeder Fehler endet in nil.
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            // Nur 2xx akzeptieren.
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }

            // Antwort parsen: erwartet Feld "embedding" als Array von Zahlen.
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["embedding"] as? [Any] else {
                return nil
            }

            // Jede Zahl robust nach Float wandeln (NSNumber deckt Int/Double/etc. ab).
            var vector: [Float] = []
            vector.reserveCapacity(raw.count)
            for element in raw {
                guard let number = element as? NSNumber else { return nil }
                vector.append(number.floatValue)
            }

            // Leeres Array gilt als Fehler.
            guard !vector.isEmpty else { return nil }
            return vector
        } catch {
            // Nicht erreichbar, Timeout, Parse-Fehler usw.
            return nil
        }
    }
}
