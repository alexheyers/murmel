import Foundation

/// Mehrstufiger Sprach-Dialog über Ollama (`/api/chat`) — das Hirn des Gesprächs-Modus.
///
/// Hält den Gesprächsverlauf im Speicher (rollendes Fenster), schickt System +
/// Verlauf + neue Nutzer-Äußerung an Ollama und gibt eine KURZE, gesprochen
/// klingende Antwort zurück (keine Listen/kein Markdown — wird sowieso vorgelesen).
///
/// Robust: Wirft nie. Bei Ollama-Fehler/Timeout → `nil` (Aufrufer sagt dann nichts).
/// Ist das primäre Modell nicht vorhanden (z. B. 7B noch nicht gezogen), wird einmal
/// automatisch auf das Fallback-Modell (qwen2.5:3b) zurückgefallen.
@MainActor
final class ConversationEngine {

    private let baseURL: String
    private let model: String
    private let fallbackModel: String
    private let session: URLSession
    /// Optionaler RAG-Retriever: liefert zur Frage passenden Kontext aus den eigenen
    /// Daten (oder "" wenn nichts/aus). Ist er gesetzt, antwortet Murmel GEERDET auf
    /// den Nutzer-Daten ("Kai, die dich kennt").
    private let retrieve: ((String) async -> String)?

    /// Gesprächsverlauf (ohne System-Prompt, ohne RAG-Kontext). Rollendes Fenster.
    private(set) var history: [[String: String]] = []
    /// Wie viele Nachrichten (User+Assistent) maximal erhalten bleiben.
    private let maxHistory = 12

    init(baseURL: String, model: String, fallbackModel: String = "qwen2.5:3b",
         retrieve: ((String) async -> String)? = nil) {
        self.baseURL = baseURL.hasSuffix("/")
            ? String(baseURL.reversed().drop(while: { $0 == "/" }).reversed())
            : baseURL
        self.model = model
        self.fallbackModel = fallbackModel
        self.retrieve = retrieve

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Verlauf löschen (neues Gespräch beginnen).
    func reset() { history.removeAll() }

    /// Nimmt die gesprochene Nutzer-Äußerung, ergänzt den Verlauf, fragt Ollama
    /// und gibt die (gesprochen-bereinigte) Antwort zurück. `nil` bei Fehler.
    func respond(to userText: String) async -> String? {
        let user = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return nil }

        // RAG: passenden Kontext aus den eigenen Daten holen (falls Retriever gesetzt).
        let context = (await retrieve?(user)) ?? ""
        if !context.isEmpty { Log.line("ConversationEngine: RAG-Kontext (\(context.count) Zeichen)") }

        // Chat-Nachrichten = System + Verlauf + (ephemerer) Kontext + Frage.
        // Der Kontext wird NICHT im Verlauf gespeichert (sonst wächst er ungebremst).
        let chatMsgs = Self.assembleForChat(history: history, context: context, user: user)

        // Erst primäres Modell, dann (bei „model not found") Fallback.
        var answer = await chat(model: model, messages: chatMsgs)
        if answer == nil, model != fallbackModel {
            Log.line("ConversationEngine: \(model) nicht verfügbar → Fallback \(fallbackModel)")
            answer = await chat(model: fallbackModel, messages: chatMsgs)
        }
        guard let raw = answer else { return nil }

        let spoken = Self.spokenClean(raw)
        guard !spoken.isEmpty else { return nil }

        // Verlauf erst bei Erfolg fortschreiben (rollendes Fenster einhalten).
        history.append(["role": "user", "content": user])
        history.append(["role": "assistant", "content": spoken])
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        return spoken
    }

    // MARK: - HTTP

    private func chat(model: String, messages: [[String: String]]) async -> String? {
        do {
            guard let url = URL(string: baseURL + "/api/chat") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60

            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": false,
                "options": ["temperature": 0.4]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil  // u. a. 404 = Modell nicht vorhanden → Aufrufer macht Fallback
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let msg = json["message"] as? [String: Any],
                let content = msg["content"] as? String
            else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Reine Logik (testbar ohne Netz)

    /// System-Prompt: Murmel als gesprochener Assistent — kurz, natürlich, kein Markdown.
    nonisolated static func systemPrompt() -> String {
        [
            "Du bist Murmel, ein gesprochener Assistent auf dem Mac. Du UNTERHÄLTST dich —",
            "deine Antworten werden laut vorgelesen.",
            "",
            "Regeln:",
            "- Antworte auf Deutsch, kurz und natürlich, wie im Gespräch (1–4 Sätze).",
            "- KEIN Markdown, KEINE Aufzählungen, KEINE Code-Blöcke, KEINE Emojis — reiner Fließtext.",
            "- Komm auf den Punkt. Wenn du etwas nicht weißt, sag es ehrlich und kurz.",
            "- Stelle höchstens EINE knappe Rückfrage, wenn nötig.",
            "- Wird dir Kontext aus den Daten/der Notion des Nutzers gegeben, stütze deine Antwort darauf.",
            "  Geht es um die KONKRETEN Daten/Projekte des Nutzers und der Kontext deckt das nicht ab,",
            "  sag das ehrlich statt zu erfinden. ALLGEMEINE Fragen darfst du aus deinem Wissen beantworten."
        ].joined(separator: "\n")
    }

    /// System-Prompt + Verlauf zu Ollama-Messages zusammensetzen (ohne RAG-Kontext).
    nonisolated static func assemble(_ history: [[String: String]]) -> [[String: String]] {
        var msgs: [[String: String]] = [["role": "system", "content": systemPrompt()]]
        msgs.append(contentsOf: history)
        return msgs
    }

    /// Wie `assemble`, plus einen ephemeren RAG-Kontext-Block VOR der neuen Frage.
    /// Reihenfolge: System · Verlauf · (Kontext) · Frage. Der Kontext landet bewusst
    /// NICHT im persistenten Verlauf.
    nonisolated static func assembleForChat(history: [[String: String]], context: String, user: String) -> [[String: String]] {
        var msgs: [[String: String]] = [["role": "system", "content": systemPrompt()]]
        msgs.append(contentsOf: history)
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            msgs.append(["role": "system",
                         "content": "Kontext aus den Daten des Nutzers (nutze ihn, wenn er zur Frage passt):\n\n" + ctx])
        }
        msgs.append(["role": "user", "content": user])
        return msgs
    }

    /// Macht eine LLM-Antwort „sprechbar": entfernt Markdown/Code/Emojis/URLs,
    /// staucht Whitespace. (Falls das Modell trotz Prompt doch formatiert.)
    nonisolated static func spokenClean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "```", with: " ")
        t = regexReplace(t, #"`[^`]*`"#, " ")                       // Inline-Code
        t = regexReplace(t, #"\[([^\]]+)\]\([^)]+\)"#, "$1")        // [Text](url) → Text
        t = regexReplace(t, #"https?://\S+"#, " ")                  // URLs
        t = regexReplace(t, #"[^0-9A-Za-zÄÖÜäöüß .,!?;:()\-\n]"#, " ")  // Emojis/Symbole
        t = regexReplace(t, #"\s+"#, " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func regexReplace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
