import Foundation
import SQLite3

/// SQLite-Destructor-Konstante: weist SQLite an, gebundene Text-Werte intern zu
/// kopieren. Ohne dies wäre der von Swift gehaltene String-Puffer nach Rückkehr
/// aus der Bind-Funktion ungültig, was zu Datenmüll/Crashes führen kann.
/// `SQLITE_TRANSIENT` ist in den C-Headern ein Makro `((sqlite3_destructor_type)-1)`
/// und muss in Swift über `unsafeBitCast` nachgebaut werden.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistiert den Diktat-Verlauf in einer lokalen SQLite-Datenbank
/// (`~/.murmel/history.sqlite`).
///
/// Wichtig: Das `sqlite3`-Handle ist NICHT threadsafe. Deshalb laufen ALLE
/// Datenbank-Zugriffe über eine interne serielle `DispatchQueue`. Schreibzugriffe
/// (`add`) feuern asynchron, Lesezugriffe (`recent`, `search`) blockieren via
/// `queue.sync` und liefern ihr Ergebnis zurück.
final class HistoryStore: HistoryStoring {

    /// Das geöffnete SQLite-Datenbank-Handle. `nil`, falls das Öffnen scheiterte
    /// (in dem Fall verhalten sich alle Methoden als No-Op bzw. liefern leere Listen).
    private var db: OpaquePointer?

    /// Serielle Queue, über die jeder DB-Zugriff serialisiert wird.
    private let queue = DispatchQueue(label: "de.murmel.history-store")

    // MARK: - Init

    /// Öffnet (bzw. erstellt) die Datenbank und legt die Tabelle an, falls nötig.
    init() {
        // Sicherstellen, dass das ~/.murmel-Verzeichnis existiert, bevor wir
        // versuchen die DB-Datei dort anzulegen.
        MurmelPaths.ensureDirectories()

        let path = MurmelPaths.historyDB.path

        // Öffnen synchron auf der seriellen Queue, damit von Anfang an alle
        // Zugriffe auf demselben Thread-Kontext laufen.
        queue.sync {
            if sqlite3_open(path, &db) != SQLITE_OK {
                // Öffnen fehlgeschlagen: Handle aufräumen und deaktivieren.
                let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unbekannt"
                NSLog("HistoryStore: sqlite3_open fehlgeschlagen (\(path)): \(msg)")
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

    /// Legt die `history`-Tabelle an, falls sie noch nicht existiert.
    /// Muss innerhalb von `queue` aufgerufen werden.
    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            raw TEXT NOT NULL,
            final TEXT NOT NULL,
            style TEXT NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "unbekannt"
            NSLog("HistoryStore: CREATE TABLE fehlgeschlagen: \(msg)")
        }
        // sqlite3_exec alloziert errMsg ggf. selbst — muss freigegeben werden.
        if errMsg != nil { sqlite3_free(errMsg) }
    }

    // MARK: - HistoryStoring

    /// Fügt einen neuen Verlaufseintrag ein. Feuert asynchron (kein Warten nötig,
    /// das Diktat soll nicht durch DB-I/O blockiert werden).
    func add(raw: String, final: String, style: DictationStyle) {
        let ts = Date().timeIntervalSince1970
        let styleRaw = style.rawValue

        queue.async { [weak self] in
            guard let self, let db = self.db else { return }

            let sql = "INSERT INTO history (ts, raw, final, style) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("HistoryStore: prepare INSERT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            // Statement in jedem Fall am Ende finalisieren.
            defer { sqlite3_finalize(stmt) }

            // Parameter-Indizes sind 1-basiert.
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, final, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, styleRaw, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("HistoryStore: INSERT step fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Liefert die letzten `limit` Einträge, neueste zuerst.
    func recent(limit: Int) -> [HistoryEntry] {
        queue.sync {
            guard let db = self.db else { return [] }

            let sql = "SELECT id, ts, raw, final, style FROM history ORDER BY id DESC LIMIT ?;"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("HistoryStore: prepare recent fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))
            return self.collectRows(from: stmt)
        }
    }

    /// Volltext-„LIKE"-Suche über `final` und `raw`. Maximal 50 Treffer, neueste zuerst.
    func search(_ query: String) -> [HistoryEntry] {
        queue.sync {
            guard let db = self.db else { return [] }

            let sql = """
            SELECT id, ts, raw, final, style FROM history
            WHERE final LIKE ? OR raw LIKE ?
            ORDER BY id DESC LIMIT 50;
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("HistoryStore: prepare search fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            // Suchmuster mit Wildcards umschließen, damit Teilstrings matchen.
            let pattern = "%" + query + "%"
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT)
            return self.collectRows(from: stmt)
        }
    }

    // MARK: - Helpers

    /// Iteriert über alle Result-Rows eines vorbereiteten SELECT-Statements und
    /// baut daraus `HistoryEntry`-Objekte. Erwartet die Spalten-Reihenfolge
    /// `id, ts, raw, final, style`.
    /// Muss innerhalb von `queue` aufgerufen werden.
    private func collectRows(from stmt: OpaquePointer?) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let raw = textColumn(stmt, 2)
            let final = textColumn(stmt, 3)
            let styleRaw = textColumn(stmt, 4)

            // Fallback auf `.raw`, falls der gespeicherte Stil unbekannt ist.
            let style = DictationStyle(rawValue: styleRaw) ?? .raw

            entries.append(
                HistoryEntry(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: ts),
                    raw: raw,
                    final: final,
                    style: style
                )
            )
        }
        return entries
    }

    /// Liest eine Text-Spalte sicher aus. Liefert "" bei NULL.
    private func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
