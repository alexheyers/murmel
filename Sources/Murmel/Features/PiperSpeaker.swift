import Foundation

/// Neuronale Sprachausgabe über **Piper** (Stimme „Thorsten", de_DE) — komplett lokal.
///
/// Ruft die Piper-CLI der venv auf (`python -m piper -m <modell> -f <wav>`, Text über
/// stdin) und spielt das Ergebnis mit `afplay` ab. Läuft auf einer eigenen seriellen
/// Queue, damit die UI nie blockiert. Ist Piper nicht installiert (Pfade fehlen),
/// wird der `fallback` (System-TTS) benutzt — Murmel ist also IMMER sprechfähig.
final class PiperSpeaker {

    private let pythonPath: String
    private let modelPath: String
    /// Ausweich-Sprachausgabe (System-Stimme), wenn Piper nicht verfügbar ist.
    private let fallback: (String) -> Void

    private let queue = DispatchQueue(label: "de.alexheyers.murmel.piper")
    /// Aktuell laufende Prozesse (für stop()).
    private var current: [Process] = []
    private let lock = NSLock()

    init(pythonPath: String, modelPath: String, fallback: @escaping (String) -> Void) {
        self.pythonPath = pythonPath
        self.modelPath = modelPath
        self.fallback = fallback
    }

    /// Ist Piper einsatzbereit (venv-Python ausführbar + Stimmmodell vorhanden)?
    var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: pythonPath) && fm.fileExists(atPath: modelPath)
    }

    /// Spricht den Text. Leerer Text wird ignoriert; eine laufende Ausgabe wird gestoppt.
    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        guard isAvailable else {
            fallback(t)  // kein Piper → System-Stimme
            return
        }

        stop()
        queue.async { [weak self] in
            self?.synthesizeAndPlay(t)
        }
    }

    /// Stoppt eine laufende Ausgabe sofort (Piper + afplay).
    func stop() {
        lock.lock()
        let procs = current
        current.removeAll()
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    // MARK: - Intern

    private func synthesizeAndPlay(_ text: String) {
        let wav = NSTemporaryDirectory() + "murmel_piper_\(UInt64.random(in: 0..<UInt64.max)).wav"
        defer { try? FileManager.default.removeItem(atPath: wav) }

        // 1) Synthese: python -m piper -m <modell> -f <wav>, Text über stdin.
        let piper = Process()
        piper.executableURL = URL(fileURLWithPath: pythonPath)
        piper.arguments = Self.piperArguments(modelPath: modelPath, outputWav: wav)
        let stdin = Pipe()
        piper.standardInput = stdin
        piper.standardOutput = FileHandle.nullDevice
        piper.standardError = FileHandle.nullDevice

        do {
            try piper.run()
            track(piper)
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
            piper.waitUntilExit()
            untrack(piper)
        } catch {
            untrack(piper)
            fallback(text)  // Synthese fehlgeschlagen → System-Stimme
            return
        }

        guard FileManager.default.fileExists(atPath: wav),
              (try? FileManager.default.attributesOfItem(atPath: wav)[.size] as? Int) ?? 0 > 0 else {
            fallback(text)
            return
        }

        // 2) Abspielen via afplay.
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = [wav]
        do {
            try play.run()
            track(play)
            play.waitUntilExit()
            untrack(play)
        } catch {
            untrack(play)
        }
    }

    private func track(_ p: Process) {
        lock.lock(); current.append(p); lock.unlock()
    }

    private func untrack(_ p: Process) {
        lock.lock(); current.removeAll { $0 == p }; lock.unlock()
    }

    /// Argumente für `python -m piper` (reine Logik → im Selbsttest prüfbar).
    static func piperArguments(modelPath: String, outputWav: String) -> [String] {
        ["-m", "piper", "-m", modelPath, "-f", outputWav]
    }
}
