import Foundation

/// Transkribiert WAV-Dateien über die whisper.cpp-CLI als Unterprozess.
///
/// Ruft die `whisper-cli`-Binary mit `-nt -np` auf (keine Zeitstempel,
/// keine Fortschrittsausgabe), liest die erkannten Zeilen von stdout und
/// fasst sie zu einem getrimmten String zusammen.
final class WhisperTranscriber: Transcribing {

    /// Absoluter Pfad zur whisper.cpp-CLI-Binary (z.B. `.../whisper-cli`).
    private let binaryPath: String
    /// Absoluter Pfad zur GGUF/GGML-Modelldatei.
    private let modelPath: String
    /// Sprachcode für Whisper (z.B. "de", "en", "auto").
    private let language: String

    init(binaryPath: String, modelPath: String, language: String) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.language = language
    }

    // MARK: - Transcribing

    func transcribe(_ wav: URL) async throws -> String {
        let fm = FileManager.default

        // 1) Vorbedingungen prüfen: Binary muss ausführbar, Modell muss vorhanden sein.
        guard fm.isExecutableFile(atPath: binaryPath) else {
            throw MurmelError.whisperBinaryMissing(binaryPath)
        }
        guard fm.fileExists(atPath: modelPath) else {
            throw MurmelError.whisperModelMissing(modelPath)
        }

        // 2) Prozess in einer Continuation ausführen, damit die async-Funktion
        //    sauber wartet, ohne den aufrufenden (Main-)Thread zu blockieren.
        //    Der eigentliche Aufruf läuft in einem detached Task auf einem
        //    Hintergrund-Thread; Process.run() + waitUntilExit() blockieren dort.
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try Self.runWhisper(
                        binaryPath: self.binaryPath,
                        modelPath: self.modelPath,
                        language: self.language,
                        wav: wav
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Subprozess

    /// Führt whisper-cli synchron aus und liefert den getrimmten Transkripttext.
    /// Wird ausschließlich vom Hintergrund-Task aufgerufen (blockierend).
    private static func runWhisper(
        binaryPath: String,
        modelPath: String,
        language: String,
        wav: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        // Argumente: Modell, Eingabedatei, Sprache, keine Zeitstempel, kein Progress.
        process.arguments = [
            "-m", modelPath,
            "-f", wav.path,
            "-l", language,
            "-nt",
            "-np"
        ]

        // Separate Pipes für stdout (Transkript) und stderr (Diagnose).
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Prozess starten. Schlägt run() fehl (z.B. ENOENT trotz Vorprüfung),
        // melden wir das als Transkriptionsfehler.
        do {
            try process.run()
        } catch {
            throw MurmelError.transcriptionFailed("Start fehlgeschlagen: \(error.localizedDescription)")
        }

        // Pipes VOR waitUntilExit() vollständig leeren, damit der Kernel-Buffer
        // bei viel Output nicht volläuft und den Prozess blockiert (Deadlock-Schutz).
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        // Exit-Code != 0 → Transkription fehlgeschlagen, stderr-Auszug mitgeben.
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let snippet = stderrText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // stderr-Auszug auf eine handhabbare Länge begrenzen.
            let limited = snippet.count > 500 ? String(snippet.prefix(500)) + "…" : snippet
            let detail = limited.isEmpty
                ? "Exit-Code \(process.terminationStatus)"
                : limited
            throw MurmelError.transcriptionFailed(detail)
        }

        // stdout dekodieren und Zeilen zu einem sauberen String zusammenfassen.
        let rawOutput = String(data: stdoutData, encoding: .utf8) ?? ""
        let joined = rawOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
