import Foundation

/// Transkribiert WAV-Dateien über einen **residenten** whisper.cpp-Server
/// (`whisper-server`) statt bei jedem Aufruf eine kalte `whisper-cli`-Instanz zu starten.
///
/// Warum: Bei der Live-Vorschau (Streaming) wird mehrmals pro Sekunde transkribiert.
/// Ein kalter CLI-Start lädt jedes Mal das Modell neu in den Speicher — das ist der
/// teuerste Teil. Der Server lädt das Modell **einmal** und behält es geladen; jede
/// Anfrage geht dann per HTTP an `POST /inference` und ist deutlich schneller
/// (gemessen ~0,11 s statt ~0,35 s, und der Vorsprung wächst mit der Audiolänge).
///
/// Robustheit:
///  - Der finale Diktat-Lauf nutzt weiterhin `whisper-cli` (large-v3-turbo) — dieser
///    Transcriber ist ausschließlich für die *Vorschau* gedacht.
///  - Ist der Server (noch) nicht erreichbar (Warmlaufphase, Start fehlgeschlagen),
///    fällt `transcribe` automatisch auf `fallback` (CLI) zurück. Die Vorschau bleibt
///    damit IMMER funktionsfähig; der Server ist eine reine Beschleunigung.
///  - Die Sprache wird **pro Anfrage** mitgeschickt (`language`-Feld). Damit ist ein
///    bereits laufender (ggf. mit anderer Startsprache gestarteter) Server unkritisch —
///    empirisch verifiziert, dass das Request-Feld die Startsprache überschreibt.
/// Thread-sicher: alle veränderlichen Zustände (`process`) werden ausschließlich
/// über die serielle `lifecycleQueue` angefasst; alles andere ist immutable.
/// Daher als `@unchecked Sendable` markiert — z.B. fürs Abräumen aus dem
/// App-Terminate-Callback.
final class WhisperServerTranscriber: Transcribing, @unchecked Sendable {

    /// Absoluter Pfad zur `whisper-server`-Binary.
    private let binaryPath: String
    /// Absoluter Pfad zum (kleinen) Vorschau-Modell (z.B. ggml-base.bin).
    private let modelPath: String
    /// Sprachcode, der bei jeder Anfrage mitgeschickt wird.
    private let language: String
    private let host: String
    private let port: Int
    /// Wird genutzt, wenn der Server nicht erreichbar ist (i.d.R. ein CLI-Transcriber).
    private let fallback: Transcribing?

    /// Serielle Queue für den Lebenszyklus des Server-Prozesses. Alle Zugriffe auf
    /// `process` laufen ausschließlich hier — damit ist der Zustand thread-sicher.
    private let lifecycleQueue = DispatchQueue(label: "de.murmel.whisperserver.lifecycle")
    private var process: Process?

    private let session: URLSession

    init(binaryPath: String,
         modelPath: String,
         language: String,
         host: String = "127.0.0.1",
         port: Int = 8771,
         fallback: Transcribing? = nil) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.language = language
        self.host = host
        self.port = port
        self.fallback = fallback

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - URLs

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
    var inferenceURL: URL { baseURL.appendingPathComponent("inference") }

    // MARK: - Lebenszyklus

    /// Stellt sicher, dass ein Server läuft (idempotent, nicht blockierend für den Aufrufer).
    /// Früh aufrufen (App-Start / Streaming-Beginn), damit das Modell vor dem ersten
    /// Tick warm ist. Macht NICHTS, wenn bereits ein eigener oder fremder Server antwortet.
    func ensureRunning() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // Läuft unser eigener Prozess bereits? (run() kehrt sofort zurück; der Port
            // wird ggf. kurz danach gebunden — ein folgender Tick fällt solange auf CLI zurück.)
            if let p = self.process, p.isRunning { return }
            // Antwortet schon ein (fremder oder verwaister) Server auf dem Port? Dann adoptieren.
            if self.portResponds() { return }
            // Vorbedingungen: Binary ausführbar, Modell vorhanden.
            let fm = FileManager.default
            guard fm.isExecutableFile(atPath: self.binaryPath),
                  fm.fileExists(atPath: self.modelPath) else { return }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: self.binaryPath)
            p.arguments = [
                "-m", self.modelPath,
                "-l", self.language,
                "-nt",
                "--host", self.host,
                "--port", String(self.port)
            ]
            // Server-Logs verwerfen (gehen sonst ins Nirvana / blockieren Pipes nicht).
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Stirbt der Prozess (z.B. Port belegt → Bind-Fehler), Referenz lösen,
            // damit ein späterer ensureRunning() neu starten bzw. adoptieren kann.
            p.terminationHandler = { [weak self] _ in
                self?.lifecycleQueue.async { self?.process = nil }
            }
            do {
                try p.run()
                self.process = p
            } catch {
                self.process = nil
            }
        }
    }

    /// Beendet den selbst gestarteten Server. Synchron, damit der Kindprozess beim
    /// App-Beenden zuverlässig terminiert wird (Process-Kinder sterben auf macOS NICHT
    /// automatisch mit dem Elternprozess).
    func shutdown() {
        lifecycleQueue.sync {
            if let p = process, p.isRunning { p.terminate() }
            process = nil
        }
    }

    /// Kurzer, synchroner Erreichbarkeits-Check: antwortet irgendetwas auf dem Port?
    /// Läuft nur auf der lifecycleQueue (Hintergrund) und blockiert dort kurz.
    private func portResponds(timeout: TimeInterval = 0.35) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var alive = false
        var req = URLRequest(url: baseURL)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let task = session.dataTask(with: req) { _, resp, _ in
            // Jede HTTP-Antwort (auch 404) bedeutet: der Port lebt.
            if resp != nil { alive = true }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.25)
        return alive
    }

    // MARK: - Transcribing

    func transcribe(_ wav: URL) async throws -> String {
        do {
            return try await transcribeViaServer(wav)
        } catch {
            // Server nicht erreichbar / Fehler → Vorschau über CLI retten, statt zu scheitern.
            if let fallback { return try await fallback.transcribe(wav) }
            throw error
        }
    }

    private func transcribeViaServer(_ wav: URL) async throws -> String {
        let audio = try Data(contentsOf: wav)
        let boundary = "MurmelBoundary-\(UUID().uuidString)"

        var req = URLRequest(url: inferenceURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = Self.multipartBody(boundary: boundary, audio: audio, language: language)
        let (data, response) = try await session.upload(for: req, from: body)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MurmelError.transcriptionFailed("whisper-server HTTP \(code)")
        }
        return Self.parseText(data)
    }

    // MARK: - Hilfsfunktionen (statisch + testbar)

    /// Baut den multipart/form-data-Body für `POST /inference`.
    /// Felder: `file` (WAV), `response_format=json`, `language`, `temperature=0.0`.
    static func multipartBody(boundary: String, audio: Data, language: String) -> Data {
        var body = Data()
        let dashes = "--\(boundary)\r\n"

        func appendField(_ name: String, _ value: String) {
            body.append(dashes.data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Datei-Teil zuerst.
        body.append(dashes.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)

        appendField("response_format", "json")
        appendField("language", language)
        appendField("temperature", "0.0")

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Liest den Text aus der Server-Antwort. Bevorzugt JSON `{"text":"…"}`,
    /// fällt auf Klartext zurück. Führende/abschließende Whitespaces/Newlines
    /// werden getrimmt (whisper.cpp liefert oft " …\n").
    static func parseText(_ data: Data) -> String {
        if let obj = try? JSONDecoder().decode(InferenceResponse.self, from: data) {
            return obj.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let plain = String(data: data, encoding: .utf8) ?? ""
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct InferenceResponse: Decodable { let text: String }
}
