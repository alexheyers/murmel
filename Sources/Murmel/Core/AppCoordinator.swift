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
    /// Live-Vorschau (Streaming) über einen residenten whisper-server (base-Modell).
    /// Fällt intern auf eine kalte whisper-cli zurück, falls der Server nicht läuft.
    private let previewTranscriber: WhisperServerTranscriber
    private let polisher: OllamaPolisher

    // Streaming-Vorschau
    private let overlay = LiveOverlay()
    private var streamTimer: Timer?
    private var previewBusy = false
    /// Zuletzt im Overlay gezeigte Vorschau — für den Anti-Flacker-Schutz.
    private var lastPreviewText = ""

    // Auto-Modus: Ziel-App zum Aufnahme-Zeitpunkt merken (Murmel selbst stiehlt keinen
    // Fokus, aber der Wert wird stabil beim Drücken erfasst, nicht erst nach der Politur).
    private var pendingTargetBundleId: String?
    private var pendingTargetName: String?
    private let inserter: TextInserting
    /// Lokale Sprachausgabe (Zwei-Wege-Voice): liest Antworten vor.
    private let speaker = Speaker()
    private let hotkey: HotkeyMonitoring
    /// Ersteinrichtung (prüft/installiert Infrastruktur) — für das Setup-Fenster.
    let setupManager = SetupManager()
    /// Konkreter Store (ObservableObject) — wird auch von der Wörterbuch-UI beobachtet.
    let vocabulary: VocabularyStore
    private let history: HistoryStoring
    private let voiceCommands: VoiceCommandProcessing

    // Gesprächs-Modus (rechte ⌥): sprechen → gesprochene Antwort (Thorsten/Piper), kein Text.
    /// Zweiter, separater Hotkey-Tap nur für den Gesprächs-Modus.
    private let conversationHotkey = HotkeyMonitor(trigger: .rightOption)
    private let conversationEngine: ConversationEngine
    private let piperSpeaker: PiperSpeaker
    /// true, während eine GESPRÄCHS-Aufnahme läuft — trennt die Release-Logik vom Diktat.
    private var conversationMode = false

    // RAG / Daten-Assistent
    private let knowledgeStore: KnowledgeStore
    private let knowledgeIndexer: KnowledgeIndexing
    private let dataAssistant: DataAssisting

    init() {
        MurmelPaths.ensureDirectories()

        let s = Settings.shared
        self.recorder = AudioRecorder()
        // EIN residenter large-v3-turbo-Server für Vorschau UND finalen Lauf:
        //  • finaler Lauf warm ~0,9 s statt kalt ~3–6 s (Modell bleibt geladen)
        //  • Vorschau nutzt dasselbe Modell wie final → keine falschen Eigennamen mehr
        // Kalte whisper-cli (turbo, mit Anti-Loop-/VAD-Flags) als Fallback, falls der
        // Server (noch) nicht erreichbar ist — so bleibt das Diktat IMMER funktionsfähig.
        let coldCLI = WhisperTranscriber(
            binaryPath: s.whisperBinaryPath,
            modelPath: s.whisperModelPath,
            language: s.language,
            vadModelPath: s.vadModelPath
        )
        let server = WhisperServerTranscriber(
            binaryPath: s.whisperServerBinaryPath,
            modelPath: s.whisperModelPath,        // turbo statt base
            language: s.language,
            host: s.whisperServerHost,
            port: s.whisperServerPort,
            vadModelPath: s.vadModelPath,
            fallback: coldCLI
        )
        self.transcriber = server          // finaler Lauf (warm)
        self.previewTranscriber = server   // Live-Vorschau (dasselbe Modell)
        let pol = OllamaPolisher(baseURL: s.ollamaBaseURL, model: s.ollamaModel)
        self.polisher = pol
        self.inserter = PasteboardInserter()
        self.hotkey = HotkeyMonitor(trigger: s.hotkeyTrigger)
        self.vocabulary = VocabularyStore()
        self.history = HistoryStore()
        self.voiceCommands = VoiceCommandProcessor()

        // RAG-Bausteine: Embedding-Client + Store + Indexer + Daten-Assistent.
        let emb = OllamaEmbeddingClient(baseURL: s.ollamaBaseURL, model: s.embedModel)
        let kstore = KnowledgeStore()
        self.knowledgeStore = kstore
        self.knowledgeIndexer = KnowledgeIndexer(embedding: emb, store: kstore)
        self.dataAssistant = DataAssistant(embedding: emb, store: kstore, complete: { system, user in
            await pol.complete(system: system, user: user)
        })

        // Gesprächs-Modus: eigene Chat-Engine (mit Verlauf) + neuronale Stimme (Piper/Thorsten).
        // RAG-Retriever: bettet die Frage ein und holt die ähnlichsten Stellen aus den
        // indexierten Daten — so antwortet Thorsten GEERDET auf den eigenen Daten.
        // Piper-Fallback = System-Stimme via `say` (nur falls Piper nicht installiert ist).
        let convTopK = s.ragTopK
        let notion = NotionClient(token: s.notionToken)
        self.conversationEngine = ConversationEngine(
            baseURL: s.ollamaBaseURL,
            model: s.conversationModel,
            retrieve: { query in
                var parts: [String] = []
                // 1) Eigene indexierte Dateien (lokaler RAG).
                if let qv = await emb.embed(query) {
                    let chunks = kstore.search(queryVector: qv, k: max(1, convTopK))
                    if !chunks.isEmpty {
                        parts.append("Aus eigenen Dateien:\n"
                            + chunks.map { "[\($0.displayName)] \($0.text)" }.joined(separator: "\n\n"))
                    }
                }
                // 2) Notion (BIZ-26-SSoT) — live durchsucht.
                let notionCtx = await notion.context(for: query)
                if !notionCtx.isEmpty {
                    parts.append("Aus Notion (BIZ 26):\n" + notionCtx)
                }
                return parts.joined(separator: "\n\n")
            }
        )
        self.piperSpeaker = PiperSpeaker(
            pythonPath: s.piperPythonPath,
            modelPath: s.piperModelPath,
            fallback: { text in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                p.arguments = ["-v", "Anna", text]
                try? p.run()
            }
        )

        wireHotkey()
        wireConversationHotkey()

        // Vorschau-Server beim App-Beenden sauber stoppen (Process-Kinder sterben auf
        // macOS NICHT automatisch mit dem Elternprozess → sonst Zombie auf dem Port).
        // Den (thread-sicheren) Transcriber direkt capturen, nicht self → keine
        // MainActor-Isolation im @Sendable-Callback.
        let preview = previewTranscriber
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            preview.shutdown()
        }
    }

    // MARK: - Start

    /// Beim App-Start aufrufen: Rechte prüfen + Hotkey aktivieren.
    func activate() {
        Permissions.requestMicrophone { _ in }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        startHotkey()
        // Turbo-Server IMMER vorwärmen — der finale Lauf nutzt ihn jetzt auch (nicht nur
        // die Vorschau). So ist das Modell vor dem ersten Diktat geladen (sonst ~1,5 s extra).
        previewTranscriber.ensureRunning()
        warmUpOllamaIfNeeded()
    }

    /// Lädt das Politur-Modell (Ollama) vorab in den Speicher — aber nur, wenn ein
    /// Politur-Stil aktiv ist. Sonst zahlt das erste Politur-Diktat ~13 s Kaltstart.
    /// Bei `.raw` (keine Politur) wird nichts geladen (kein RAM verschwendet).
    func warmUpOllamaIfNeeded() {
        guard settings.currentStyle.usesPolish else { return }
        Task { _ = await polisher.complete(system: "Antworte nur mit: OK", user: "warmup") }
    }

    func startHotkey() {
        let ok = hotkey.start()
        Log.line("AppCoordinator.startHotkey() → \(ok ? "aktiv" : "FEHLGESCHLAGEN")")
        if !ok {
            phase = .error("Bedienungshilfen-Recht fehlt — bitte in den Systemeinstellungen erlauben.")
            lastError = phase == .idle ? nil : "Bedienungshilfen-Recht fehlt."
        }
        startConversationHotkey()
    }

    /// Startet den Gesprächs-Tap (rechte ⌥) — nur wenn aktiviert und die rechte ⌥ nicht
    /// schon als Diktat-Trigger belegt ist (sonst Konflikt). Idempotent.
    func startConversationHotkey() {
        guard settings.conversationEnabled, settings.hotkeyTrigger != .rightOption else {
            conversationHotkey.stop()
            return
        }
        let ok = conversationHotkey.start()
        Log.line("AppCoordinator.startConversationHotkey() → \(ok ? "aktiv" : "FEHLGESCHLAGEN")")
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

    private func wireConversationHotkey() {
        conversationHotkey.onPress = { [weak self] in
            Task { @MainActor in self?.handleConversationPress() }
        }
        conversationHotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.handleConversationRelease() }
        }
    }

    // MARK: - Gesprächs-Modus (rechte ⌥)

    private func handleConversationPress() {
        guard settings.conversationEnabled else { return }
        Log.line("handleConversationPress() — phase=\(String(describing: phase))")
        guard phase == .idle || isErrorPhase else {
            Log.line("handleConversationPress() ignoriert (phase nicht idle)")
            return
        }
        do {
            try recorder.startRecording()
            conversationMode = true
            phase = .recording
            Sounds.convStart()  // eigener Gesprächs-Ton (anders als fn-Diktat)
            // Bewusst KEIN Streaming-Overlay: im Gespräch entsteht kein Text zum Mitlesen.
        } catch {
            conversationMode = false
            phase = .error(error.localizedDescription)
            lastError = error.localizedDescription
            Sounds.fail()
            resetToIdleSoon()
        }
    }

    private func handleConversationRelease() {
        Log.line("handleConversationRelease() — phase=\(String(describing: phase)) convMode=\(conversationMode)")
        guard conversationMode, phase == .recording else { return }
        conversationMode = false
        Sounds.convStop()
        let wav = recorder.stopRecording()
        phase = .transcribing
        Task { await runConversation(wav: wav) }
    }

    /// Gesprächs-Pipeline: Aufnahme → Transkription → Chat (mit Verlauf) → gesprochene Antwort.
    /// Fügt KEINEN Text ein und schreibt NICHT in den Diktat-Verlauf.
    private func runConversation(wav: URL?) async {
        guard let wav else { phase = .idle; Sounds.soft(); return }
        do {
            let transcribed = try await transcriber.transcribe(wav, prompt: currentWhisperPrompt())
            let collapsed = TranscriptHygiene.collapseRepetitions(transcribed)
            let raw = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !TranscriptHygiene.isLikelyHallucination(raw) else {
                Log.line("Gespräch: nichts Verständliches erkannt")
                cleanup(wav); phase = .idle; Sounds.soft(); return
            }
            Log.line("Gespräch: du sagst \"\(raw)\"")

            phase = .polishing  // „denkt nach"
            let answer = await conversationEngine.respond(to: raw)
            cleanup(wav)
            guard let answer, !answer.isEmpty else {
                Log.line("Gespräch: keine Antwort (Ollama aus / Modell fehlt)")
                phase = .idle; Sounds.soft(); return
            }
            Log.line("Gespräch: Antwort \"\(answer)\"")
            Sounds.convReady()
            piperSpeaker.speak(answer)
            phase = .idle
        } catch {
            cleanup(wav)
            phase = .error(error.localizedDescription)
            lastError = error.localizedDescription
            Sounds.fail()
            resetToIdleSoon()
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
            // Ziel-App jetzt erfassen — Murmel ist eine Menubar-App ohne eigenes Fenster,
            // die frontmost-App bleibt also das Zielfenster für den Auto-Modus.
            let app = NSWorkspace.shared.frontmostApplication
            pendingTargetBundleId = app?.bundleIdentifier
            pendingTargetName = app?.localizedName
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
            // 1. Transkription (mit Prompt-Biasing auf Eigennamen/Fachbegriffe)
            Log.line("Pipeline: transkribiere \(wav.lastPathComponent)…")
            let transcribed = try await transcriber.transcribe(wav, prompt: currentWhisperPrompt())
            // De-Loop: Whisper-Wiederholungsschleifen bei längerem Audio kollabieren,
            // BEVOR der Text weiterverarbeitet/eingefügt wird.
            let raw = TranscriptHygiene.collapseRepetitions(transcribed)
            if raw != transcribed { Log.line("Pipeline: Wiederholungsschleife kollabiert (\(transcribed.count)→\(raw.count) Zeichen)") }
            Log.line("Pipeline: Rohtext = \"\(raw)\"")
            let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Leere Erkennung ODER reine Halluzination (z.B. „*Piep*" bei Stille) → nichts einfügen.
            guard !trimmedRaw.isEmpty, !TranscriptHygiene.isLikelyHallucination(trimmedRaw) else {
                if !trimmedRaw.isEmpty { Log.line("Pipeline: Halluzination verworfen (\"\(trimmedRaw)\")") }
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

            // 3a. Auto-Modus: nur wenn aktiviert UND der Nutzer auf dem Standard-Stil .raw steht,
            //     wählt Murmel den Stil nach der aktiven App. Manuelle Stilwahl bleibt unangetastet.
            let autoActive = settings.autoStyleByApp && settings.currentStyle == .raw
            let effectiveStyle: DictationStyle = autoActive
                ? (AppStyleMapper.style(forBundleId: pendingTargetBundleId, name: pendingTargetName) ?? .raw)
                : settings.currentStyle
            if autoActive {
                Log.line("Auto-Modus: App=\"\(pendingTargetName ?? "?")\" (\(pendingTargetBundleId ?? "?")) → Stil \(effectiveStyle.displayName)")
            }

            // 3b. Daten-Assistent (RAG): eigener Pfad — sucht in den eigenen Daten und fügt das Ergebnis ein.
            if effectiveStyle.isDataAssistant {
                phase = .polishing
                Log.line("Daten-Assistent: \"\(corrected)\"")
                let result = await dataAssistant.answer(instruction: corrected, topK: settings.ragTopK)
                let answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else {
                    Log.line("Daten-Assistent: kein Ergebnis (Index leer / Ollama aus / nichts gefunden)")
                    cleanup(wav); phase = .idle; Sounds.soft(); return
                }
                let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                history.add(raw: raw, final: answer, style: effectiveStyle, app: targetApp)
                phase = .inserting
                Log.line("Daten-Assistent: füge ein (\(answer.count) Zeichen, Quellen: \(result.sources.joined(separator: ", ")))")
                inserter.insert(answer)
                if settings.speakAnswers { speaker.speak(answer) }
                Sounds.done()
                if settings.streamingEnabled, !result.sources.isEmpty {
                    overlay.update("Quellen: " + result.sources.joined(separator: ", "))
                }
                cleanup(wav)
                phase = .idle
                pipelineSucceeded = true
                return
            }

            // 4. Politur / Übersetzung / Befehl / Assistent / Zusammenfassen
            let style = effectiveStyle
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

            // 5. Verlauf (inkl. App, in die eingefügt wird — Murmel selbst stiehlt keinen Fokus,
            //    also ist die frontmost-App das Zielfenster)
            let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            history.add(raw: raw, final: trimmed, style: effectiveStyle, app: targetApp)

            // 6. Einfügen
            phase = .inserting
            Log.line("Pipeline: füge ein = \"\(trimmed)\"")
            inserter.insert(trimmed)
            // Zwei-Wege-Voice: nur echte „Antwort"-Modi vorlesen (Assistent/Zusammenfassen),
            // NICHT E-Mail/Roh/Code etc.
            if settings.speakAnswers, effectiveStyle == .assistant || effectiveStyle == .summarize {
                speaker.speak(trimmed)
            }
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

    // MARK: - Vorlesen (lokale TTS)

    /// Liest den aktuellen Inhalt der Zwischenablage mit der lokalen Stimme vor.
    func speakClipboard() {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        speaker.speak(s)
    }

    /// Stoppt eine laufende Sprachausgabe.
    func stopSpeaking() {
        speaker.stop()
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

    // MARK: - Wissen / RAG

    /// Indexiert die konfigurierten Ordner + den Diktat-Verlauf neu (inkrementell).
    func reindexKnowledge() async -> IndexResult {
        await knowledgeIndexer.reindex(folders: settings.knowledgeFolders,
                                       history: history.recent(limit: 2000))
    }

    /// Anzahl indexierter Wissens-Chunks (für die UI).
    var knowledgeChunkCount: Int { knowledgeStore.chunkCount }

    // MARK: - Streaming-Vorschau

    private func startStreaming() {
        Log.line("startStreaming() — streamingEnabled=\(settings.streamingEnabled)")
        overlay.show()
        previewBusy = false
        lastPreviewText = ""
        // Server sicherstellen (idempotent — warm, falls schon gestartet).
        previewTranscriber.ensureRunning()
        // Schnellerer Takt: dank residentem Server kostet eine Vorschau nur ~0,1 s,
        // also kann das Overlay flüssiger mitlaufen. Die previewBusy-Sperre drosselt
        // automatisch, falls ein Lauf (bei langem Audio) mal länger als der Takt dauert.
        // 0,9 s Takt: das turbo-Modell braucht pro Vorschau mehr als base; die
        // previewBusy-Sperre drosselt zusätzlich automatisch bei langem Audio.
        let t = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
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
        // Vorschau-Fenster: bis 20 s ganzes Audio, darüber nur die letzten 20 s.
        // Mit dem turbo-Modell ist dieses Fenster stabil (kein base-Flackern mehr) und
        // bleibt auch bei MINUTENLANGEN Diktaten schnell — das Overlay zeigt ohnehin nur
        // die zuletzt gesprochenen Worte. Der FINALE Lauf nutzt weiter das KOMPLETTE Audio.
        guard let snap = recorder.snapshotWAV(maxSeconds: 20) else { return }
        previewBusy = true
        let prompt = currentWhisperPrompt()
        Task { @MainActor in
            defer { previewBusy = false }
            do {
                let rawPreview = try await previewTranscriber.transcribe(snap, prompt: prompt)
                let text = TranscriptHygiene.collapseRepetitions(rawPreview)
                try? FileManager.default.removeItem(at: snap)
                // Anti-Flacker: einen drastisch KÜRZEREN Tick (base-Modell-Ausreißer)
                // ignorieren, statt die gewachsene Vorschau zurückzusetzen.
                let drasticShrink = !lastPreviewText.isEmpty
                    && text.count < (lastPreviewText.count * 6) / 10
                    && lastPreviewText.count >= 20
                if phase == .recording, !text.isEmpty, !drasticShrink {
                    lastPreviewText = text
                    overlay.update(String(text.suffix(400)))
                }
                Log.line("streamingTick: \(text.count) Zeichen Vorschau")
            } catch {
                Log.line("streamingTick FEHLER: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: snap)
            }
        }
    }

    // MARK: - Whisper-Prompt-Biasing

    /// Baut den „initial prompt" für Whisper: Eigennamen + Wörterbuch-Begriffe +
    /// gängige Slash-Befehle. Dadurch erkennt Whisper diese Begriffe direkt korrekt,
    /// statt sie hinterher per Wörterbuch reparieren zu müssen.
    private func currentWhisperPrompt() -> String {
        let proper = ["Murmel", "Claude Code", "n8n", "Supabase", "Ollama", "Vercel", "GitHub"]
        let commands = ["context", "clear", "commit", "review", "compact", "model"]
        // Wörterbuch-Zielbegriffe ergänzen, Duplikate raus, Reihenfolge stabil.
        var seen = Set<String>()
        var names: [String] = []
        for term in proper + vocabulary.terms where seen.insert(term.lowercased()).inserted {
            names.append(term)
        }
        return "Kontext (Eigennamen/Fachbegriffe): " + names.joined(separator: ", ")
            + ". Slash-Befehle: " + commands.joined(separator: ", ") + "."
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
