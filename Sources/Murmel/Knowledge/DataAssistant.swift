import Foundation

/// Der RAG-Orchestrator: erfüllt eine diktierte Anweisung ausschließlich anhand der
/// eigenen Daten des Nutzers. Ablauf: Anweisung einbetten → ähnlichste Chunks suchen →
/// Kontext bauen → lokales LLM den einzufügenden Text formulieren lassen.
final class DataAssistant: DataAssisting {

    // MARK: - Abhängigkeiten

    private let embedding: EmbeddingClient
    private let store: KnowledgeStoring
    /// LLM-Funktion: System-Prompt + User-Text rein, Antwort-Text oder nil raus.
    private let complete: (_ system: String, _ user: String) async -> String?

    init(
        embedding: EmbeddingClient,
        store: KnowledgeStoring,
        complete: @escaping (_ system: String, _ user: String) async -> String?
    ) {
        self.embedding = embedding
        self.store = store
        self.complete = complete
    }

    // MARK: - DataAssisting

    func answer(instruction: String, topK: Int) async -> AssistantResult {
        // 1. Anweisung trimmen; leere Eingabe → leeres Ergebnis.
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            return AssistantResult(text: "", sources: [])
        }

        // 2. Anweisung einbetten. Embedding/Ollama aus → leeres Ergebnis.
        guard let qv = await embedding.embed(trimmedInstruction) else {
            return AssistantResult(text: "", sources: [])
        }

        // 3. Ähnlichste Chunks suchen. Keine Treffer → leeres Ergebnis.
        let chunks = store.search(queryVector: qv, k: max(1, topK))
        guard !chunks.isEmpty else {
            return AssistantResult(text: "", sources: [])
        }

        // 4. Kontext bauen: nummerierte Liste, je mit Quellname und Text.
        let kontext = chunks.enumerated().map { index, chunk in
            "[\(index + 1)] (Quelle: \(chunk.displayName))\n\(chunk.text)"
        }.joined(separator: "\n\n")

        // 5. Strikter System-Prompt (deutsch).
        let system = """
        Du bist ein Assistent, der eine diktierte Anweisung erfüllt. Nutze AUSSCHLIESSLICH den folgenden Kontext aus den eigenen Daten des Nutzers.
        Befolge Meta-Wünsche in der Anweisung (kurz / als Bulletpoints / einfügen …).
        Wenn der Kontext die Anweisung nicht abdeckt, sage das in einem kurzen Satz statt zu erfinden.
        Gib AUSSCHLIESSLICH den einzufügenden Text zurück — keine Vorrede, keine Quellenliste im Text.

        KONTEXT:
        \(kontext)
        """

        // 6. LLM aufrufen, Antwort trimmen.
        let out = await complete(system, trimmedInstruction)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 7. Quellen: eindeutige displayName, Reihenfolge erhalten, dedupliziert.
        var seen = Set<String>()
        let sources = chunks.compactMap { chunk -> String? in
            let name = chunk.displayName
            return seen.insert(name).inserted ? name : nil
        }

        // 8. Ergebnis zurückgeben.
        return AssistantResult(text: out ?? "", sources: sources)
    }
}
