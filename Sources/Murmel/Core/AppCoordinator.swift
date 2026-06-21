import Foundation
import SwiftUI

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
    private let polisher: Polishing
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
        let wav = recorder.stopRecording()
        Log.line("Aufnahme gestoppt — wav=\(wav?.lastPathComponent ?? "nil")")
        phase = .transcribing
        Task { await runPipeline(wav: wav) }
    }

    // MARK: - Pipeline

    private func runPipeline(wav: URL?) async {
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

            // 4. Politur
            phase = .polishing
            let final = await polisher.polish(
                corrected,
                style: settings.currentStyle,
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
