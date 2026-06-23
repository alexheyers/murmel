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

    /// DAUERHAFTES Gesprächs-Gedächtnis — der KOMPLETTE Verlauf, persistiert auf Platte
    /// (`~/.murmel/conversation.json`). Bleibt über Neustarts erhalten.
    private(set) var history: [[String: String]] = []
    /// So viele der jüngsten Nachrichten gehen als Kontext ins Modell (Prompt-Fenster) —
    /// das VOLLE Gedächtnis bleibt gespeichert, nur der an das LLM gereichte Ausschnitt
    /// ist begrenzt (sonst sprengt ein langer Verlauf irgendwann das Kontextfenster).
    private let maxPromptMessages = 40

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

        // Dauerhaftes Gedächtnis von der Platte laden (über Neustarts hinweg).
        self.history = Self.loadHistory()
    }

    /// Gesamtes Gedächtnis löschen (auch von der Platte). Nur auf ausdrücklichen Wunsch.
    func reset() {
        history.removeAll()
        try? FileManager.default.removeItem(at: MurmelPaths.conversationFile)
    }

    /// Nimmt die gesprochene Nutzer-Äußerung, ergänzt den Verlauf, fragt Ollama
    /// und gibt die (gesprochen-bereinigte) Antwort zurück. `nil` bei Fehler.
    func respond(to userText: String) async -> String? {
        let user = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return nil }

        // RAG: passenden Kontext aus den eigenen Daten holen (falls Retriever gesetzt).
        let context = (await retrieve?(user)) ?? ""
        if !context.isEmpty { Log.line("ConversationEngine: RAG-Kontext (\(context.count) Zeichen)") }

        // Chat-Nachrichten = System + (jüngstes Verlaufs-Fenster) + (ephemerer) Kontext + Frage.
        // Der Kontext wird NICHT im Verlauf gespeichert (sonst wächst er ungebremst).
        let windowed = Array(history.suffix(maxPromptMessages))
        let chatMsgs = Self.assembleForChat(history: windowed, context: context, user: user)

        // Erst primäres Modell, dann (bei „model not found") Fallback.
        var answer = await chat(model: model, messages: chatMsgs)
        if answer == nil, model != fallbackModel {
            Log.line("ConversationEngine: \(model) nicht verfügbar → Fallback \(fallbackModel)")
            answer = await chat(model: fallbackModel, messages: chatMsgs)
        }
        guard let raw = answer else { return nil }

        let spoken = Self.spokenClean(raw)
        guard !spoken.isEmpty else { return nil }

        // Verlauf bei Erfolg fortschreiben UND dauerhaft speichern (volles Gedächtnis).
        history.append(["role": "user", "content": user])
        history.append(["role": "assistant", "content": spoken])
        saveHistory()
        return spoken
    }

    // MARK: - Dauerhaftes Gedächtnis (Platte)

    private func saveHistory() {
        guard let data = try? JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted]) else { return }
        try? data.write(to: MurmelPaths.conversationFile, options: .atomic)
    }

    nonisolated static func loadHistory() -> [[String: String]] {
        guard let data = try? Data(contentsOf: MurmelPaths.conversationFile),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return arr
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

    /// System-Prompt = editierbare Persona (`~/.murmel/persona.md`, von Alex anpassbar)
    /// + nicht verhandelbare Betriebsregeln (Format, Grounding, Umgang mit Unklarem).
    nonisolated static func systemPrompt() -> String {
        let persona = (try? String(contentsOf: MurmelPaths.personaFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = (persona?.isEmpty == false) ? persona! : MurmelPaths.defaultPersonaText
        return identity + "\n\n" + operatingRules
    }

    /// Harte Betriebsregeln — gelten IMMER, auch wenn die Persona editiert wird.
    /// Verhindern das „frei drauflos reden" bei verhörter/leerer Eingabe.
    nonisolated static let operatingRules = """
    ## Betriebsregeln (immer)
    - Antworte auf die konkrete FRAGE — direkt, gesprochen, in EIGENEN Worten. Du führst ein
      Gespräch, keinen Vortrag.
    - Lies den bereitgestellten Kontext NIEMALS vor und zähle ihn NICHT als Liste auf. Nimm daraus
      NUR das eine, das die Frage beantwortet, und fasse es in ein, zwei Sätzen zusammen.
    - Reiner Fließtext: KEIN Markdown, KEINE Aufzählungen, KEINE Nummerierung, keine Emojis
      (du wirst vorgelesen).
    - Findest du im Kontext keine Antwort auf die FRAGE, sag das in EINEM kurzen Satz
      ("Dazu finde ich gerade nichts in deinen Daten") — recitiere NICHT ersatzweise etwas anderes.
    - Bei unklarer oder offensichtlich verhörter Eingabe: kurz nachfragen statt zu raten.
    - Allgemeine Wissensfragen normal aus deinem Wissen beantworten. Erfinde nie Fakten über Alex.
    - Halte dich kurz: höchstens drei Sätze, außer es wird ausdrücklich mehr verlangt.
    - KEINE Regieanweisungen, KEINE Platzhalter, kein "Lass mich nachsehen" oder "[Suche…]".
      Du hast den Kontext bereits — antworte sofort und direkt mit dem Ergebnis.
    """

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
