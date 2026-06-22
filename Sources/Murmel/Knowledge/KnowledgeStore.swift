import Foundation
import SQLite3

/// SQLite-Destructor-Konstante: weist SQLite an, gebundene Text-/BLOB-Werte intern
/// zu kopieren. Ohne dies wäre der von Swift gehaltene Puffer nach Rückkehr aus der
/// Bind-Funktion ungültig, was zu Datenmüll/Crashes führen kann.
/// `SQLITE_TRANSIENT` ist in den C-Headern ein Makro `((sqlite3_destructor_type)-1)`
/// und muss in Swift über `unsafeBitCast` nachgebaut werden.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistiert Wissens-Chunks samt Embedding-Vektoren in einer lokalen SQLite-DB
/// (`~/.murmel/knowledge.sqlite`) und sucht die ähnlichsten per Cosine-Similarity.
///
/// Wichtig: Das `sqlite3`-Handle ist NICHT threadsafe. Deshalb laufen ALLE
/// Datenbank-Zugriffe über eine interne serielle `DispatchQueue`. Schreibzugriffe
/// (`replace`, `prune`) feuern asynchron, Lesezugriffe (`mtime`, `search`,
/// `knownFilePaths`, `chunkCount`) blockieren via `queue.sync` und liefern ihr
/// Ergebnis zurück.
final class KnowledgeStore: KnowledgeStoring {

    /// Das geöffnete SQLite-Datenbank-Handle. `nil`, falls das Öffnen scheiterte
    /// (in dem Fall verhalten sich alle Methoden als No-Op bzw. liefern leere Werte).
    private var db: OpaquePointer?

    /// Serielle Queue, über die jeder DB-Zugriff serialisiert wird.
    private let queue = DispatchQueue(label: "de.murmel.knowledge-store")

    // MARK: - Init

    /// Öffnet (bzw. erstellt) die Datenbank und legt Tabelle + Index an, falls nötig.
    init() {
        // Sicherstellen, dass das ~/.murmel-Verzeichnis existiert, bevor wir
        // versuchen die DB-Datei dort anzulegen.
        MurmelPaths.ensureDirectories()

        let path = MurmelPaths.knowledgeDB.path

        // Öffnen synchron auf der seriellen Queue, damit von Anfang an alle
        // Zugriffe auf demselben Thread-Kontext laufen.
        queue.sync {
            if sqlite3_open(path, &db) != SQLITE_OK {
                // Öffnen fehlgeschlagen: Handle aufräumen und deaktivieren.
                let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unbekannt"
                NSLog("KnowledgeStore: sqlite3_open fehlgeschlagen (\(path)): \(msg)")
                if db != nil { sqlite3_close(db) }
                db = nil
                return
            }
            createTableIfNeeded()
        }
    }

    deinit {
        // Handle sauber schließen, falls geöffnet.
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Schema

    /// Legt die `chunks`-Tabelle samt Index auf `path` an, falls noch nicht vorhanden.
    /// Muss innerhalb von `queue` aufgerufen werden.
    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            path TEXT NOT NULL,
            mtime REAL NOT NULL,
            ord INTEGER NOT NULL,
            text TEXT NOT NULL,
            vector BLOB
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "unbekannt"
            NSLog("KnowledgeStore: CREATE TABLE fehlgeschlagen: \(msg)")
        }
        if errMsg != nil { sqlite3_free(errMsg) }

        // Index auf `path` beschleunigt mtime-Lookup, DELETE und prune.
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);", nil, nil, nil)
    }

    // MARK: - KnowledgeStoring

    /// Letzte bekannte mtime eines Pfads (MAX über alle Zeilen), nil wenn keine Zeile
    /// existiert. Für inkrementelles Indexieren: unverändert → überspringen.
    func mtime(forPath path: String) -> Double? {
        queue.sync {
            guard let db = self.db else { return nil }

            let sql = "SELECT MAX(mtime) FROM chunks WHERE path = ?;"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("KnowledgeStore: prepare mtime fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            // MAX(...) liefert bei fehlenden Zeilen NULL → als "kein Eintrag" werten.
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, 0)
        }
    }

    /// Ersetzt ALLE Chunks eines Pfads: erst DELETE der alten Zeilen, dann INSERT
    /// der neuen (ord = Reihenfolge-Index). Feuert asynchron — Indexierung soll die
    /// UI nicht blockieren.
    func replace(path: String, source: String, mtime: Double, chunks: [(text: String, vector: [Float])]) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }

            // 1) Alte Zeilen dieses Pfads entfernen.
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE path = ?;", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, path, -1, SQLITE_TRANSIENT)
                if sqlite3_step(delStmt) != SQLITE_DONE {
                    NSLog("KnowledgeStore: DELETE step fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                }
            } else {
                NSLog("KnowledgeStore: prepare DELETE fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(delStmt)

            // 2) Neue Chunks einfügen — ein vorbereitetes Statement, mehrfach gebunden.
            let sql = "INSERT INTO chunks (source, path, mtime, ord, text, vector) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("KnowledgeStore: prepare INSERT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            for (ord, chunk) in chunks.enumerated() {
                // Vor jedem Durchlauf zurücksetzen + alte Bindings lösen.
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, mtime)
                sqlite3_bind_int(stmt, 4, Int32(ord))
                sqlite3_bind_text(stmt, 5, chunk.text, -1, SQLITE_TRANSIENT)

                // Vektor als rohe Float-Bytes (little-endian) als BLOB ablegen.
                let data = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                if data.isEmpty {
                    sqlite3_bind_null(stmt, 6)
                } else {
                    // `withUnsafeBytes` hält den Puffer nur während des Aufrufs gültig;
                    // SQLITE_TRANSIENT lässt SQLite eine eigene Kopie ziehen.
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                }

                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("KnowledgeStore: INSERT step fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }
    }

    /// Entfernt alle Datei-Chunks (`source='file'`), deren `path` NICHT in `keepPaths`
    /// liegt — also gelöschte/verschobene Dateien aus dem Index räumen.
    /// Feuert asynchron.
    func prune(keepPaths: Set<String>) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }

            // Erst alle bekannten Datei-Pfade sammeln, dann gezielt löschen.
            var existing: Set<String> = []
            var selStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT DISTINCT path FROM chunks WHERE source = 'file';", -1, &selStmt, nil) == SQLITE_OK {
                while sqlite3_step(selStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(selStmt, 0) {
                        existing.insert(String(cString: c))
                    }
                }
            } else {
                NSLog("KnowledgeStore: prepare prune-SELECT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(selStmt)

            let toDelete = existing.subtracting(keepPaths)
            guard !toDelete.isEmpty else { return }

            var delStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE source = 'file' AND path = ?;", -1, &delStmt, nil) == SQLITE_OK else {
                NSLog("KnowledgeStore: prepare prune-DELETE fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(delStmt) }

            for path in toDelete {
                sqlite3_reset(delStmt)
                sqlite3_clear_bindings(delStmt)
                sqlite3_bind_text(delStmt, 1, path, -1, SQLITE_TRANSIENT)
                if sqlite3_step(delStmt) != SQLITE_DONE {
                    NSLog("KnowledgeStore: prune-DELETE step fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }
    }

    /// Liefert die `k` ähnlichsten Chunks zum Query-Vektor. Lädt alle Zeilen, berechnet
    /// pro Zeile die Cosine-Similarity und sortiert absteigend.
    /// (Brute-Force — für lokale Wissensmengen ausreichend, kein ANN-Index nötig.)
    func search(queryVector: [Float], k: Int) -> [RetrievedChunk] {
        guard k > 0 else { return [] }

        return queue.sync {
            guard let db = self.db else { return [] }

            // Norm des Query-Vektors einmal vorab — wird für jede Zeile gebraucht.
            let queryNorm = KnowledgeStore.norm(queryVector)

            let sql = "SELECT path, source, text, vector FROM chunks;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("KnowledgeStore: prepare search fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var results: [RetrievedChunk] = []

            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = self.textColumn(stmt, 0)
                let source = self.textColumn(stmt, 1)
                let text = self.textColumn(stmt, 2)
                let vector = KnowledgeStore.floatsFromBlob(stmt, 3)

                // Cosine berechnen; bei Norm 0 oder Längen-Mismatch → score 0.
                let score = KnowledgeStore.cosine(queryVector, queryNorm, vector)

                results.append(
                    RetrievedChunk(path: path, source: source, text: text, score: score)
                )
            }

            // Absteigend nach Ähnlichkeit, Top-k.
            results.sort { $0.score > $1.score }
            if results.count > k {
                results = Array(results.prefix(k))
            }
            return results
        }
    }

    /// Distinct-Pfade aller Datei-Chunks (`source='file'`) — z.B. um zu wissen, was
    /// bereits indexiert ist.
    func knownFilePaths() -> Set<String> {
        queue.sync {
            guard let db = self.db else { return [] }

            let sql = "SELECT DISTINCT path FROM chunks WHERE source = 'file';"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("KnowledgeStore: prepare knownFilePaths fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var paths: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    paths.insert(String(cString: c))
                }
            }
            return paths
        }
    }

    /// Gesamtzahl gespeicherter Chunks (COUNT(*)).
    var chunkCount: Int {
        queue.sync {
            guard let db = self.db else { return 0 }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Helpers

    /// Liest eine Text-Spalte sicher aus. Liefert "" bei NULL.
    private func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    /// Liest eine BLOB-Spalte und interpretiert sie als roh gepackte `[Float]`
    /// (4 Bytes pro Element, native Byte-Order — passend zum Schreiben in `replace`).
    private static func floatsFromBlob(_ stmt: OpaquePointer?, _ index: Int32) -> [Float] {
        guard let raw = sqlite3_column_blob(stmt, index) else { return [] }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0 else { return [] }

        let count = byteCount / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }

        // Bytes in ein frisches [Float] kopieren (der SQLite-Puffer ist nur bis zum
        // nächsten step/reset gültig).
        var floats = [Float](repeating: 0, count: count)
        floats.withUnsafeMutableBytes { dest in
            memcpy(dest.baseAddress, raw, count * MemoryLayout<Float>.stride)
        }
        return floats
    }

    /// Euklidische Norm (||v||) eines Vektors.
    private static func norm(_ v: [Float]) -> Double {
        var sum = 0.0
        for x in v { sum += Double(x) * Double(x) }
        return sum.squareRoot()
    }

    /// Cosine-Similarity zwischen `a` (Norm vorab als `aNorm`) und `b`.
    /// Rückgabe 0, falls eine Norm 0 ist oder die Längen nicht übereinstimmen.
    private static func cosine(_ a: [Float], _ aNorm: Double, _ b: [Float]) -> Double {
        guard a.count == b.count, aNorm > 0 else { return 0 }

        var dot = 0.0
        var bSum = 0.0
        for i in 0..<a.count {
            let av = Double(a[i])
            let bv = Double(b[i])
            dot += av * bv
            bSum += bv * bv
        }
        let bNorm = bSum.squareRoot()
        guard bNorm > 0 else { return 0 }
        return dot / (aNorm * bNorm)
    }
}
