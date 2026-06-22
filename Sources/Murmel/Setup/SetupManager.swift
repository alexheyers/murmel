import Foundation

/// Prüft und installiert alles, was Murmel zur Laufzeit braucht — direkt aus der App
/// heraus (statt manuell `setup.sh` im Terminal zu laufen). Wird vom Ersteinrichtungs-
/// Fenster (`SetupView`) genutzt: „App einmal starten → Einrichtung läuft mit Zwischenfragen".
///
/// Alles bleibt lokal/0 €: Homebrew (Voraussetzung), whisper.cpp, Whisper-Modelle,
/// VAD-Modell, Ollama + Qwen + Embedding-Modell.
@MainActor
final class SetupManager: ObservableObject {

    /// Die einzelnen Einrichtungs-Bausteine, in Installations-Reihenfolge.
    enum Step: String, CaseIterable, Identifiable {
        case homebrew, whisper, whisperModel, vadModel, ollama, qwen, embed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .homebrew:    return "Homebrew"
            case .whisper:     return "whisper.cpp (Spracherkennung)"
            case .whisperModel:return "Whisper-Modell large-v3-turbo (~1,5 GB)"
            case .vadModel:    return "VAD-Modell (Anti-Halluzination)"
            case .ollama:      return "Ollama (lokales LLM)"
            case .qwen:        return "Sprachmodell qwen2.5:3b (~2 GB)"
            case .embed:       return "Embedding-Modell nomic-embed-text (~270 MB)"
            }
        }

        var detail: String {
            switch self {
            case .homebrew:    return "Paketmanager — Voraussetzung. Kann nicht automatisch installiert werden."
            case .whisper:     return "Wandelt deine Stimme lokal in Text (whisper-cli + whisper-server)."
            case .whisperModel:return "Das genaue Modell für den finalen Text."
            case .vadModel:    return "Erkennt Sprechpausen — verhindert erfundene Texte bei Stille."
            case .ollama:      return "Führt das lokale Sprachmodell aus (Politur, Assistent, RAG)."
            case .qwen:        return "Räumt Rohtext auf, beantwortet Fragen — alles offline."
            case .embed:       return "Für den Daten-Assistenten (Suche in deinen eigenen Dateien)."
            }
        }

        /// Ob dieser Schritt von der App automatisch installiert werden kann.
        var isAutoInstallable: Bool { self != .homebrew }
    }

    enum Status: Equatable {
        case unknown
        case checking
        case present          // war schon da
        case missing
        case installing
        case done             // gerade installiert
        case failed(String)

        var isSatisfied: Bool { self == .present || self == .done }
    }

    @Published private(set) var status: [Step: Status] = [:]
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isBusy = false

    /// Alles erledigt? (Homebrew zählt mit — ohne Homebrew geht der Rest nicht.)
    var isComplete: Bool { Step.allCases.allSatisfy { (status[$0] ?? .unknown).isSatisfied } }

    // MARK: - Pfade / Quellen

    private let modelsDir = MurmelPaths.modelsDir
    private var turboModel: URL { modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin") }
    private var vadModel: URL { modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin") }
    private let turboURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    private let vadURL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"

    // MARK: - Prüfen

    /// Prüft alle Schritte (greift nicht ins System ein).
    func checkAll() async {
        MurmelPaths.ensureDirectories()
        for step in Step.allCases { status[step] = .checking }
        for step in Step.allCases {
            status[step] = await check(step) ? .present : .missing
        }
    }

    private func check(_ step: Step) async -> Bool {
        let fm = FileManager.default
        switch step {
        case .homebrew:
            return fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
                || fm.isExecutableFile(atPath: "/usr/local/bin/brew")
        case .whisper:
            let cli = await which("whisper-cli")
            let server = await which("whisper-server")
            return cli && server
        case .whisperModel:
            return fm.fileExists(atPath: turboModel.path)
        case .vadModel:
            return fm.fileExists(atPath: vadModel.path)
        case .ollama:
            return await which("ollama")
        case .qwen:
            return await ollamaHasModel("qwen2.5:3b")
        case .embed:
            return await ollamaHasModel("nomic-embed-text")
        }
    }

    // MARK: - Installieren

    /// Installiert der Reihe nach alle fehlenden, automatisch installierbaren Schritte.
    /// Homebrew wird NICHT automatisch installiert — fehlt es, bricht der Lauf mit Hinweis ab.
    func installMissing() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // Ohne Homebrew geht der Rest nicht.
        if !(status[.homebrew] ?? .unknown).isSatisfied {
            status[.homebrew] = .failed("Homebrew fehlt — bitte zuerst installieren (Knopf unten).")
            append("✗ Homebrew fehlt. Bitte zuerst installieren, dann erneut auf Einrichten klicken.")
            return
        }

        for step in Step.allCases where step.isAutoInstallable {
            if (status[step] ?? .unknown).isSatisfied { continue }
            status[step] = .installing
            append("▶︎ \(step.title) …")
            let ok = await install(step)
            status[step] = ok ? .done : .failed("Installation fehlgeschlagen — siehe Protokoll.")
            append(ok ? "✓ \(step.title) fertig" : "✗ \(step.title) fehlgeschlagen")
            if !ok { return }   // Abbruch, da Folgeschritte oft aufeinander aufbauen
        }
        append(isComplete ? "🎉 Einrichtung abgeschlossen — Murmel ist bereit." : "Einige Schritte fehlen noch.")
    }

    private func install(_ step: Step) async -> Bool {
        switch step {
        case .homebrew:
            return false   // nicht automatisch
        case .whisper:
            guard await run("brew install whisper-cpp").code == 0 else { return false }
            return await which("whisper-cli")
        case .whisperModel:
            return await download(turboURL, to: turboModel)
        case .vadModel:
            return await download(vadURL, to: vadModel)
        case .ollama:
            guard await run("brew install ollama").code == 0 else { return false }
            // Dienst starten (idempotent) — sonst schlägt das Modell-Ziehen fehl.
            _ = await run("brew services start ollama")
            return await which("ollama")
        case .qwen:
            await ensureOllamaRunning()
            return await run("ollama pull qwen2.5:3b").code == 0
        case .embed:
            await ensureOllamaRunning()
            return await run("ollama pull nomic-embed-text").code == 0
        }
    }

    // MARK: - Hilfen

    /// Stellt sicher, dass der Ollama-Dienst antwortet (für die Modell-Downloads).
    private func ensureOllamaRunning() async {
        if await run("curl -s --max-time 3 http://127.0.0.1:11434/api/tags").code == 0 { return }
        _ = await run("brew services start ollama || (ollama serve >/dev/null 2>&1 &)")
        // kurz Zeit zum Hochfahren geben (Polling statt fixem sleep)
        for _ in 0..<10 {
            if await run("curl -s --max-time 2 http://127.0.0.1:11434/api/tags").code == 0 { return }
            _ = await run("sleep 1")
        }
    }

    private func which(_ tool: String) async -> Bool {
        await run("command -v \(tool)").code == 0
    }

    private func ollamaHasModel(_ name: String) async -> Bool {
        guard await which("ollama") else { return false }
        let r = await run("ollama list 2>/dev/null")
        return r.code == 0 && r.output.contains(name)
    }

    /// Lädt eine Datei per curl (atomar über .part), gibt true bei Erfolg.
    private func download(_ url: String, to dest: URL) async -> Bool {
        let part = dest.path + ".part"
        let r = await run("curl -L --fail -o '\(part)' '\(url)' && mv -f '\(part)' '\(dest.path)'")
        return r.code == 0 && FileManager.default.fileExists(atPath: dest.path)
    }

    /// Führt einen Befehl in einer Login-Shell aus (lädt PATH → brew/ollama auffindbar).
    @discardableResult
    private func run(_ command: String) async -> (code: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription)); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    /// Den offiziellen Homebrew-Installationsbefehl (für Copy-Knopf im UI).
    static let homebrewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}
