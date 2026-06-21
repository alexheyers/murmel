import Foundation

/// Einfacher Datei-Logger für Diagnose. Schreibt nach ~/.murmel/murmel.log.
/// Bewusst simpel gehalten — bei Bedarf später entfernbar.
enum Log {
    private static let queue = DispatchQueue(label: "de.alexheyers.murmel.log")
    private static let fileURL = MurmelPaths.home.appendingPathComponent("murmel.log")

    static func line(_ message: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(ts)] \(message)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
