import Foundation

/// Live-Zugriff auf die BIZ-26-Notion (Single Source of Truth) als Wissensquelle
/// für den Gesprächs-Modus. Pro Frage wird Notion durchsucht, die Top-Treffer
/// werden als Klartext geholt und als Kontext an das lokale LLM gereicht
/// (→ Thorsten antwortet geerdet auf den Notion-Inhalten).
///
/// Robust: Wirft NIE. Bei fehlendem Token / Fehler / Timeout → "" (kein Kontext).
final class NotionClient {

    private let token: String
    private let session: URLSession
    /// Notion-API-Version (stabil). Self-hosted Integration-Token funktioniert damit.
    private static let apiVersion = "2022-06-28"

    init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    /// Ist ein Token hinterlegt?
    var isConfigured: Bool { !token.isEmpty }

    /// Baut den Kontext-Block für eine Frage: Notion durchsuchen → Top-Treffer als
    /// Klartext → formatiert zusammenfügen. "" wenn nichts/aus/Fehler.
    /// - Parameters:
    ///   - query: die gesprochene Frage.
    ///   - maxPages: wie viele Treffer-Seiten inhaltlich geladen werden.
    ///   - maxChars: harte Längenbegrenzung des gesamten Kontexts.
    func context(for query: String, maxPages: Int = 3, maxChars: Int = 4000) async -> String {
        guard isConfigured else { return "" }
        let hits = await search(query: query, pageSize: maxPages)
        guard !hits.isEmpty else { return "" }

        var blocks: [String] = []
        for hit in hits {
            let text = await pageText(id: hit.id)
            let body = text.isEmpty ? "(kein Textinhalt)" : text
            blocks.append("## \(hit.title)\n\(body)")
        }
        let joined = blocks.joined(separator: "\n\n")
        return joined.count > maxChars ? String(joined.prefix(maxChars)) : joined
    }

    // MARK: - HTTP

    /// Volltextsuche über die Notion-Workspace → [(Seiten-ID, Titel)].
    func search(query: String, pageSize: Int) async -> [(id: String, title: String)] {
        do {
            guard let url = URL(string: "https://api.notion.com/v1/search") else { return [] }
            var req = makeRequest(url: url, method: "POST")
            req.httpBody = Self.searchBody(query: query, pageSize: pageSize)
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            return Self.parseSearchTitles(data)
        } catch {
            return []
        }
    }

    /// Holt den Klartext der ersten Block-Ebene einer Seite.
    func pageText(id: String) async -> String {
        do {
            guard let url = URL(string: "https://api.notion.com/v1/blocks/\(id)/children?page_size=50") else { return "" }
            let req = makeRequest(url: url, method: "GET")
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return "" }
            return Self.extractPlainText(fromBlocks: data)
        } catch {
            return ""
        }
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - Reine Logik (testbar ohne Netz)

    static func searchBody(query: String, pageSize: Int) -> Data {
        let body: [String: Any] = ["query": query, "page_size": max(1, pageSize)]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Liest (id, Titel) aus einer Notion-`/v1/search`-Antwort. Der Titel steckt in
    /// der Property vom Typ "title" (Name variiert je Datenbank).
    static func parseSearchTitles(_ data: Data) -> [(id: String, title: String)] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { return [] }

        var out: [(id: String, title: String)] = []
        for obj in results {
            guard let id = obj["id"] as? String else { continue }
            let title = titleFromProperties(obj["properties"] as? [String: Any]) ?? "Ohne Titel"
            out.append((id: id, title: title))
        }
        return out
    }

    /// Sucht in den Properties die Title-Property (type == "title") und fügt ihren Text zusammen.
    static func titleFromProperties(_ properties: [String: Any]?) -> String? {
        guard let properties else { return nil }
        for (_, value) in properties {
            guard let prop = value as? [String: Any],
                  (prop["type"] as? String) == "title",
                  let rich = prop["title"] as? [[String: Any]] else { continue }
            let text = rich.compactMap { $0["plain_text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Extrahiert Klartext aus einer `/v1/blocks/{id}/children`-Antwort.
    /// Deckt die gängigen Text-Blöcke ab (paragraph, headings, Listen, quote, callout, to_do, toggle).
    static func extractPlainText(fromBlocks data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { return "" }

        let textTypes = ["paragraph", "heading_1", "heading_2", "heading_3",
                         "bulleted_list_item", "numbered_list_item", "to_do",
                         "quote", "callout", "toggle"]
        var lines: [String] = []
        for block in results {
            guard let type = block["type"] as? String, textTypes.contains(type),
                  let inner = block[type] as? [String: Any],
                  let rich = inner["rich_text"] as? [[String: Any]] else { continue }
            let line = rich.compactMap { $0["plain_text"] as? String }.joined()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }
}
