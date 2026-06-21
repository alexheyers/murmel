import Foundation
import SwiftUI
import AppKit

/// Zentrale Steuerung: besitzt alle Komponenten, verdrahtet den Hotkey
/// und fährt die Diktat-Pipeline (Aufnahme → Transkription → Befehle →
/// Wörterbuch → Politur → Verlauf → Einfügen).
@MainActor
final class AppCoordinator: ObservableObject {

    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var lastError: String?

    let settings = Settings.shared

    // Komponenten (konkrete Klassen kommen aus den Einzeldateien).
    private let recorder: AudioRecording
    private let transcriber: Transcribing
    /// Schnelles base-Modell für die Live-Vorschau (Streaming).
    private let previewTranscriber: WhisperTranscriber
    private let polisher: OllamaPolisher

    // Streaming-Vorschau
    private let overlay = LiveOverlay()
    private var streamTimer: Timer?
    private var previewBusy = false
    private let inserter: TextInserting
    private let hotkey: HotkeyMonitoring
    /// Konkreter Store (ObservableObject) — wird auch von der Wörterbuch-UI beobachtet.
    let vocabulary: VocabularyStore
    private let history: HistoryStoring
    private let voiceCommands: VoiceCommandProcessing

    init() {
        MurmelPaths.ensureDirectories()

        let s = Settings.shared
        self.recorder = AudioRecorder()
        self.transcriber = WhisperTranscriber(
            binaryPath: s.whisperBinaryPath,
            modelPath: s.whisperModelPath,
            language: s.language
        )
        self.previewTranscriber = WhisperTranscriber(
            binaryPath: s.whisperBinaryPath,
            modelPath: s.previewModelPath,
            language: s.language
        )
        self.polisher = OllamaPolisher(baseURL: s.ollamaBaseURL, model: s.ollamaModel)
        self.inserter = PasteboardInserter()
        self.hotkey = HotkeyMonitor(trigger: s.hotkeyTrigger)
        self.vocabulary = VocabularyStore()
        self.history = HistoryStore()
        self.voiceCommands = VoiceCommandProcessor()

        wireHotkey()
    }

    // MARK: - Start

    /// Beim App-Start aufrufen: Rechte prüfen + Hotkey aktivieren.
    func activate() {
        Permissions.requestMicrophone { _ in }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        startHotkey()
    }

    func startHotkey() {
        let ok = hotkey.start()
        Log.line("AppCoordinator.startHotkey() → \(ok ? "aktiv" : "FEHLGESCHLAGEN")")
        if !ok {
            phase = .error("Bedienungshilfen-Recht fehlt — bitte in den Systemeinstellungen erlauben.")
            lastError = phase == .idle ? nil : "Bedienungshilfen-Recht fehlt."
        }
    }

    /// Trigger zur Laufzeit wechseln (aus den Einstellungen).
    func updateTrigger(_ trigger: HotkeyTrigger) {
        hotkey.trigger = trigger
    }

    private func wireHotkey() {
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.handlePress() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.handleRelease() }
        }
    }

    // MARK: - Push-to-talk

    private func handlePress() {
        Log.line("handlePress() — phase=\(String(describing: phase))")
        guard phase == .idle || isErrorPhase else {
            Log.line("handlePress() ignoriert (phase nicht idle)")
            return
        }
        do {
            try recorder.startRecording()
            phase = .recording
            Log.line("Aufnahme gestartet")
            Sounds.start()
            if settings.streamingEnabled { startStreaming() }
        } catch {
            phase = .error(error.localizedDescription)
            lastError = error.localizedDescription
            Sounds.fail()
            resetToIdleSoon()
        }
    }

    private func handleRelease() {
        Log.line("handleRelease() — phase=\(String(describing: phase))")
        guard phase == .recording else { return }
        Sounds.stop()
        stopStreamTimer()
        if settings.streamingEnabled { overlay.setState(.thinking) }
        let wav = recorder.stopRecording()
        Log.line("Aufnahme gestoppt — wav=\(wav?.lastPathComponent ?? "nil")")
        phase = .transcribing
        Task { await runPipeline(wav: wav) }
    }

    // MARK: - Pipeline

    private func runPipeline(wav: URL?) async {
        // Overlay-Lebenszyklus zentral: bei Erfolg „fertig", sonst ausblenden.
        var pipelineSucceeded = false
        defer { if pipelineSucceeded { finishOverlay() } else { cancelOverlay() } }

        guard let wav else {
            phase = .idle
            Sounds.soft()
            return
        }
        do {
            // 1. Transkription
            Log.line("Pipeline: transkribiere \(wav.lastPathComponent)…")
            let raw = try await transcriber.transcribe(wav)
            Log.line("Pipeline: Rohtext = \"\(raw)\"")
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cleanup(wav)
                phase = .idle
                Sounds.soft()
                return
            }

            // 2. Sprachbefehle
            let cmd = voiceCommands.process(raw)
            if cmd.aborted {
                cleanup(wav)
                phase = .idle
                Sounds.soft()
                return
            }

            // 3. Wörterbuch
            let corrected = vocabulary.correct(cmd.text)

            // 4. Politur / Übersetzung / Befehl / Assistent / Zusammenfassen
            let style = settings.currentStyle
            let llmInput: String
            let llmInstruction: String
            if style.usesClipboardInput {
                // Befehls-Modus: gesprochene Anweisung wird auf den kopierten Text angewandt.
                let clip = (NSPasteboard.general.string(forType: .string) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clip.isEmpty else {
                    Log.line("Befehls-Modus: Zwischenablage leer → nichts zu tun")
                    cleanup(wav); phase = .idle; Sounds.soft(); return
                }
                llmInput = clip
                llmInstruction = corrected
            } else {
                llmInput = corrected
                llmInstruction = settings.instruction(for: style)
            }
            phase = .polishing
            let final = await polisher.polish(
                llmInput,
                style: style,
                instruction: llmInstruction,
                vocabularyHint: vocabulary.terms
            )
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                cleanup(wav)
                phase = .idle
                Sounds.soft()
                return
            }

            // 5. Verlauf
            history.add(raw: raw, final: trimmed, style: settings.currentStyle)

            // 6. Einfügen
            phase = .inserting
            Log.line("Pipeline: füge ein = \"\(trimmed)\"")
            inserter.insert(trimmed)
            Sounds.done()

            cleanup(wav)
            phase = .idle
            pipelineSucceeded = true
        } catch {
            // Audio NICHT löschen — Diktat geht nicht verloren.
            Log.line("Pipeline FEHLER: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
            lastError = error.localizedDescription
            Sounds.fail()
            resetToIdleSoon()
        }
    }

    // MARK: - Verlauf (für die UI)

    func recentHistory(limit: Int = 10) -> [HistoryEntry] {
        history.recent(limit: limit)
    }

    func searchHistory(_ query: String) -> [HistoryEntry] {
        history.search(query)
    }

    /// Einen Verlaufseintrag erneut einfügen.
    func reinsert(_ entry: HistoryEntry) {
        inserter.insert(entry.final)
        Sounds.done()
    }

    // MARK: - Auto-Wörterbuch

    /// Lässt Ollama aus dem Verlauf wahrscheinliche Falschschreibungen → Korrektbegriffe vorschlagen.
    func suggestVocabulary() async -> [VocabSuggestion] {
        let texts = history.recent(limit: 80).map { $0.raw }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return [] }

        let existing = vocabulary.terms.joined(separator: ", ")
        let system = [
            "Du analysierst diktierte Texte und findest Fachbegriffe, Tool- oder Eigennamen,",
            "die eine Spracherkennung wahrscheinlich FALSCH geschrieben hat (z.B. 'n acht n' statt 'n8n').",
            "Gib AUSSCHLIESSLICH ein JSON-Array zurück, max. 8 Einträge:",
            "[{\"wrong\":\"falsch gehörte Schreibweise\",\"right\":\"korrekte Schreibweise\"}]",
            "- Nur echte, plausible Fälle. Keine bereits korrekten Begriffe. Kein Fließtext, nur JSON."
        ].joined(separator: "\n")
        let user = "Bereits bekannt (ignorieren): \(existing)\n\nDiktate:\n" + texts.joined(separator: "\n")

        guard let raw = await polisher.complete(system: system, user: user) else { return [] }
        return Self.parseSuggestions(raw)
    }

    /// Extrahiert das JSON-Array aus der (ggf. umrahmten) Modell-Antwort.
    private static func parseSuggestions(_ raw: String) -> [VocabSuggestion] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var out: [VocabSuggestion] = []
        for obj in arr {
            guard let w = (obj["wrong"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let r = (obj["right"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !w.isEmpty, !r.isEmpty, w.lowercased() != r.lowercased() else { continue }
            let key = w.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(VocabSuggestion(wrong: w, right: r))
        }
        return out
    }

    // MARK: - Streaming-Vorschau

    private func startStreaming() {
        overlay.show()
        previewBusy = false
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.streamingTick() }
        }
        streamTimer = t
    }

    private func stopStreamTimer() {
        streamTimer?.invalidate()
        streamTimer = nil
    }

    private func finishOverlay() {
        stopStreamTimer()
        guard settings.streamingEnabled else { return }
        overlay.setState(.done)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            overlay.hide()
        }
    }

    private func cancelOverlay() {
        stopStreamTimer()
        overlay.hide()
    }

    /// Ein Vorschau-Tick: aktuellen Audio-Stand schnappen, mit base-Modell
    /// transkribieren und ins Overlay schreiben. Überlappungen werden vermieden.
    private func streamingTick() {
        guard settings.streamingEnabled, phase == .recording, !previewBusy else { return }
        guard let snap = recorder.snapshotWAV() else { return }
        previewBusy = true
        Task { @MainActor in
            defer { previewBusy = false }
            do {
                let text = try await previewTranscriber.transcribe(snap)
                try? FileManager.default.removeItem(at: snap)
                // Nur den jüngsten Abschnitt zeigen; truncationMode(.head) im Overlay
                // sorgt zusätzlich dafür, dass stets die zuletzt gesprochenen Worte sichtbar sind.
                if phase == .recording, !text.isEmpty { overlay.update(String(text.suffix(400))) }
            } catch {
                try? FileManager.default.removeItem(at: snap)
            }
        }
    }

    // MARK: - Helpers

    private var isErrorPhase: Bool {
        if case .error = phase { return true }
        return false
    }

    private func cleanup(_ wav: URL) {
        try? FileManager.default.removeItem(at: wav)
    }

    private func resetToIdleSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if isErrorPhase { phase = .idle }
        }
    }
}
