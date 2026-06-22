import Foundation

/// Indexiert Ordner + Diktat-Verlauf inkrementell in den `KnowledgeStore`.
///
/// Ablauf je Lauf:
///  1. Für jeden Ordner rekursiv alle (Text-)Dateien durchgehen.
///  2. Per mtime-Vergleich entscheiden, ob neu indexiert werden muss.
///  3. Datei in Chunks schneiden, jeden Chunk embedden, Ergebnisse in den Store schreiben.
///  4. Diktat-Verlauf genauso behandeln (Quelle "history").
///  5. Am Ende `prune` mit allen gesehenen Datei-Pfaden (history wird nicht geprunt).
final class KnowledgeIndexer: KnowledgeIndexing {

    private let embedding: EmbeddingClient
    private let store: KnowledgeStoring

    /// Erlaubte Text-Datei-Endungen (kleingeschrieben, ohne Punkt).
    private static let textExtensions: Set<String> = [
        "md", "txt", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css",
        "json", "yaml", "yml", "sh", "c", "h", "cpp", "rs", "go", "java",
        "kt", "rb", "php", "sql", "csv", "xml",
        // Zusätzliche text-artige Endungen (Müll-Filter / robusterer RAG-Index).
        "log", "toml", "ini", "tex", "srt", "markdown"
    ]

    /// Verzeichnis-Namen, die komplett übersprungen werden (Müll-/Build-Ordner).
    /// Wird beim Walk geprüft, sobald der Name IRGENDWO im Pfad auftaucht.
    private static let skippedDirNames: Set<String> = [
        "node_modules", ".build", ".git", "dist", "build", ".next", "Pods",
        ".venv", "venv", "__pycache__", "DerivedData", ".cache", ".swiftpm",
        "vendor", ".Trash", ".vercel", "target", ".gradle"
    ]

    /// Obergrenze für Dateigröße (2 MB) — Größeres wird ignoriert.
    private static let maxFileBytes = 2_000_000

    /// Ziel-Chunk-Größe in Zeichen.
    private static let chunkMin = 600
    private static let chunkMax = 900

    init(embedding: EmbeddingClient, store: KnowledgeStoring) {
        self.embedding = embedding
        self.store = store
    }

    // MARK: - Öffentliche API

    func reindex(folders: [String], history: [HistoryEntry]) async -> IndexResult {
        var result = IndexResult()
        // Alle in diesem Lauf gesehenen Datei-Pfade (für prune).
        var seenFilePaths = Set<String>()

        // --- 1) Ordner / Dateien ---
        for folder in folders {
            let urls = collectFiles(in: folder)
            for fileURL in urls {
                let path = fileURL.path
                seenFilePaths.insert(path)
                await indexFile(at: fileURL, path: path, into: &result)
            }
        }

        // --- 2) Diktat-Verlauf ---
        for entry in history {
            await indexHistoryEntry(entry, into: &result)
        }

        // --- 3) Aufräumen: gelöschte Dateien aus dem Store entfernen ---
        // Nur Datei-Pfade übergeben; history-Pfade bleiben dadurch unberührt,
        // weil der Store ausschließlich source=="file"-Pfade verwaltet/pruned.
        store.prune(keepPaths: seenFilePaths)

        return result
    }

    // MARK: - Datei-Indexierung

    /// Sammelt rekursiv alle in Frage kommenden Datei-URLs eines Ordners.
    private func collectFiles(in folder: String) -> [URL] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: folder)

        // Existiert der Ordner überhaupt und ist es ein Verzeichnis?
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true } // Fehler bei einzelnen Einträgen ignorieren, weiterlaufen
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent

            // Versteckte Einträge (beginnend mit ".") und bekannte Müll-Ordner überspringen.
            let isHidden = name.hasPrefix(".")
            let isSkippedDir = Self.skippedDirNames.contains(name)

            // Verzeichnis? -> ggf. Abstieg unterbinden.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = values?.isDirectory ?? false

            if isDirectory {
                if isHidden || isSkippedDir {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Ab hier: reguläre Datei (oder Unbekanntes -> überspringen).
            guard values?.isRegularFile ?? false else { continue }
            if isHidden { continue }

            // Sicherheitsnetz: liegt ein Müll-Ordner-Name IRGENDWO im Pfad
            // (z.B. weil skipDescendants den Einstieg knapp verpasst hat), Datei überspringen.
            if Self.pathContainsSkippedDir(url) { continue }

            // Endung prüfen.
            let ext = url.pathExtension.lowercased()
            guard Self.textExtensions.contains(ext) else { continue }

            files.append(url)
        }
        return files
    }

    /// True, wenn einer der Müll-Ordner-Namen als Pfad-Komponente in `url` vorkommt.
    private static func pathContainsSkippedDir(_ url: URL) -> Bool {
        for component in url.pathComponents where skippedDirNames.contains(component) {
            return true
        }
        return false
    }

    /// Indexiert eine einzelne Datei (inkrementell).
    private func indexFile(at url: URL, path: String, into result: inout IndexResult) async {
        let fm = FileManager.default

        // mtime ermitteln.
        guard
            let attrs = try? fm.attributesOfItem(atPath: path),
            let modDate = attrs[.modificationDate] as? Date
        else {
            result.errors += 1
            return
        }
        let fileMtime = modDate.timeIntervalSince1970

        // Größe prüfen (>~1 MB überspringen, zählt nicht als Fehler).
        if let size = attrs[.size] as? NSNumber, size.intValue > Self.maxFileBytes {
            return
        }

        // Inkrementell: unverändert? -> überspringen.
        if let known = store.mtime(forPath: path), known == fileMtime {
            result.skipped += 1
            return
        }

        // Inhalt lesen (UTF-8). Misslingt das, als Fehler werten.
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            result.errors += 1
            return
        }

        await embedAndStore(
            text: content,
            path: path,
            source: "file",
            mtime: fileMtime,
            into: &result,
            countAsFile: true
        )
    }

    // MARK: - Verlaufs-Indexierung

    /// Indexiert einen Verlaufs-Eintrag (inkrementell, Quelle "history").
    private func indexHistoryEntry(_ entry: HistoryEntry, into result: inout IndexResult) async {
        let raw = entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let path = "history:\(entry.id)"
        let mtime = entry.timestamp.timeIntervalSince1970

        // Inkrementell: unverändert? -> überspringen.
        if let known = store.mtime(forPath: path), known == mtime {
            result.skipped += 1
            return
        }

        await embedAndStore(
            text: entry.raw,
            path: path,
            source: "history",
            mtime: mtime,
            into: &result,
            countAsFile: false
        )
    }

    // MARK: - Gemeinsame Chunk-/Embed-/Store-Logik

    /// Chunkt den Text, embeddet jeden Chunk und schreibt das Ergebnis in den Store.
    /// - Parameter countAsFile: true -> erhöht `filesIndexed`; false (history) -> nicht.
    private func embedAndStore(
        text: String,
        path: String,
        source: String,
        mtime: Double,
        into result: inout IndexResult,
        countAsFile: Bool
    ) async {
        let chunks = chunk(text)
        guard !chunks.isEmpty else { return }

        var stored: [(text: String, vector: [Float])] = []
        for chunkText in chunks {
            if let vector = await embedding.embed(chunkText) {
                stored.append((text: chunkText, vector: vector))
            }
        }

        // Nur schreiben, wenn mindestens ein Vektor zustande kam.
        guard !stored.isEmpty else { return }

        store.replace(path: path, source: source, mtime: mtime, chunks: stored)

        if countAsFile { result.filesIndexed += 1 }
        result.chunks += stored.count
    }

    /// Schneidet Text in Stücke von ~600–900 Zeichen, möglichst an Absatz-/Zeilengrenzen.
    private func chunk(_ text: String) -> [String] {
        // Erst an Absätzen ("\n\n") splitten, dann zu lange Absätze weiter teilen.
        let paragraphs = text.components(separatedBy: "\n\n")

        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for paragraph in paragraphs {
            let trimmedPara = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPara.isEmpty { continue }

            // Passt der Absatz noch in den aktuellen Chunk?
            if current.isEmpty {
                if trimmedPara.count <= Self.chunkMax {
                    current = trimmedPara
                } else {
                    // Zu langer Absatz: einzeln weiter teilen.
                    for piece in splitLong(trimmedPara) {
                        chunks.append(piece)
                    }
                }
            } else if current.count + 2 + trimmedPara.count <= Self.chunkMax {
                // Anhängen, solange wir unter dem Maximum bleiben.
                current += "\n\n" + trimmedPara
            } else {
                // Aktuellen Chunk abschließen.
                flush()
                if trimmedPara.count <= Self.chunkMax {
                    current = trimmedPara
                } else {
                    for piece in splitLong(trimmedPara) {
                        chunks.append(piece)
                    }
                }
            }

            // Wenn der laufende Chunk groß genug ist, gleich abschließen.
            if current.count >= Self.chunkMin {
                flush()
            }
        }
        flush()

        return chunks.filter { !$0.isEmpty }
    }

    /// Teilt einen zu langen Absatz an Zeilen-/Wortgrenzen in ~max-große Stücke.
    private func splitLong(_ paragraph: String) -> [String] {
        var pieces: [String] = []
        var current = ""

        // Bevorzugt an einzelnen Zeilen schneiden.
        let lines = paragraph.components(separatedBy: "\n")
        for line in lines {
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= Self.chunkMax {
                current += "\n" + line
            } else {
                appendTrimmed(current, to: &pieces)
                current = line
            }

            // Einzelne Zeile bereits zu lang? -> an Wortgrenzen weiter teilen.
            if current.count > Self.chunkMax {
                let split = splitByWords(current)
                // Alle bis auf das letzte Stück sind fertig; letztes bleibt "current".
                for p in split.dropLast() { appendTrimmed(p, to: &pieces) }
                current = split.last ?? ""
            }
        }
        appendTrimmed(current, to: &pieces)
        return pieces
    }

    /// Teilt einen überlangen String hart an Wortgrenzen (Fallback: an Zeichengrenze).
    private func splitByWords(_ s: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false) {
            let w = String(word)
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= Self.chunkMax {
                current += " " + w
            } else {
                appendTrimmed(current, to: &pieces)
                current = w
            }
            // Selbst ein einzelnes Wort kann zu lang sein -> hart an Zeichengrenze schneiden.
            while current.count > Self.chunkMax {
                let idx = current.index(current.startIndex, offsetBy: Self.chunkMax)
                appendTrimmed(String(current[..<idx]), to: &pieces)
                current = String(current[idx...])
            }
        }
        appendTrimmed(current, to: &pieces)
        return pieces
    }

    /// Hilfsfunktion: getrimmt anhängen, Leeres weglassen.
    private func appendTrimmed(_ s: String, to arr: inout [String]) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { arr.append(t) }
    }
}
