import Foundation
import AVFoundation

/// Nimmt das Standard-Mikrofon über AVAudioEngine auf und schreibt eine
/// 16-kHz-Mono-16-bit-PCM-WAV — exakt das Format, das whisper.cpp erwartet.
///
/// Ablauf:
///   startRecording() → Engine starten, Tap auf inputNode, jede Pufferung
///                      via AVAudioConverter auf 16 kHz Mono konvertieren und
///                      in eine AVAudioFile schreiben.
///   stopRecording()  → Engine stoppen, Tap entfernen, Datei schließen und
///                      die URL zurückgeben (oder nil bei Stille/Fehler).
///
/// Thread-Sicherheit: Die öffentlichen Methoden werden vom Main-Thread
/// aufgerufen. Der Tap-Callback läuft auf einem internen Audio-Thread —
/// alle gemeinsam genutzten Zustände werden deshalb über eine serielle
/// Queue (`stateQueue`) synchronisiert.
final class AudioRecorder: AudioRecording {

    // MARK: - Konstanten

    /// Whisper-Zielformat: 16 kHz, Mono.
    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1

    /// Mindestdauer in Sekunden — kürzere Aufnahmen gelten als versehentlich
    /// (Stille / zu kurzes Antippen) und liefern nil.
    private let minimumDuration: Double = 0.3

    // MARK: - Audio-Bausteine

    private let engine = AVAudioEngine()

    /// Wird beim Start frisch angelegt, beim Stop geschlossen/genullt.
    private var audioFile: AVAudioFile?

    /// Konvertiert vom Hardware-Input-Format auf das 16-kHz-Mono-Zielformat.
    private var converter: AVAudioConverter?

    /// Zielformat (16 kHz, Mono, Float32 — AVAudioFile schreibt es per
    /// `settings` als 16-bit PCM auf die Platte).
    private var targetFormat: AVAudioFormat?

    // MARK: - Zustand (über stateQueue synchronisiert)

    /// Serielle Queue zum Schutz der gemeinsam genutzten Felder, da der
    /// Tap-Callback auf einem anderen Thread als die Aufrufer läuft.
    private let stateQueue = DispatchQueue(label: "de.murmel.audiorecorder.state")

    /// URL der aktuell beschriebenen Datei.
    private var currentURL: URL?

    /// Anzahl bereits geschriebener Ziel-Frames (für Dauer-/Stille-Check).
    private var writtenFrames: AVAudioFrameCount = 0

    /// Ob gerade aufgenommen wird.
    private var isRecording = false

    /// Konvertierte 16-kHz-Mono-Samples im Speicher — Basis für `snapshotWAV()`
    /// (Live-Vorschau). Wird bei Start/Stop geleert. Über stateQueue geschützt.
    private var pcmSamples: [Float] = []

    // MARK: - Init

    init() {}

    /// Wärmt die Audio-Engine beim App-Start vor: initialisiert den CoreAudio-Graphen,
    /// damit der ERSTE echte `startRecording()` nicht durch den Kaltstart den Sprech-Anfang
    /// verschluckt (kurze Befehle wie „Starte …" verloren sonst das erste Wort).
    /// Startet KEINE Aufnahme — kein Mikrofon-Lämpchen, keine Daten.
    func warmUp() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
        Log.line("AudioRecorder: Engine vorgewärmt")
    }

    // MARK: - AudioRecording

    /// Startet die Aufnahme vom Standard-Mikrofon.
    /// - Throws: `MurmelError.audioEngineFailed`, wenn Format-/Converter-Setup
    ///           oder der Engine-Start scheitert.
    func startRecording() throws {
        // Verzeichnisse sicherstellen (idempotent).
        MurmelPaths.ensureDirectories()

        let inputNode = engine.inputNode

        // Hardware-Format des Mikrofons (Sample-Rate/Kanäle gibt die HW vor).
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MurmelError.audioEngineFailed("Kein gültiges Eingangsformat vom Mikrofon.")
        }

        // Zielformat für die Konvertierung: 16 kHz, Mono, Float32 (interleaved
        // irrelevant bei Mono). Dieses Format füttert den Converter.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw MurmelError.audioEngineFailed("Zielformat (16 kHz Mono) konnte nicht erstellt werden.")
        }
        self.targetFormat = targetFormat

        // Converter vom Hardware- aufs Zielformat.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MurmelError.audioEngineFailed("AVAudioConverter konnte nicht erstellt werden.")
        }
        self.converter = converter

        // Ausgabedatei mit eindeutigem Namen.
        let url = MurmelPaths.recordingsDir.appendingPathComponent("rec-\(UUID().uuidString).wav")

        // WAV-Schreib-Settings: 16-bit PCM, 16 kHz, Mono, Little-Endian.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            // AVAudioFile schreibt im durch `settings` definierten Datei-Format,
            // nimmt aber beim write() Float32-Puffer entgegen und wandelt intern
            // nach 16-bit PCM.
            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            self.audioFile = file
        } catch {
            // Aufräumen, damit ein erneuter Start sauber startet.
            cleanupAfterFailure()
            throw MurmelError.audioEngineFailed("WAV-Datei konnte nicht angelegt werden: \(error.localizedDescription)")
        }

        // Zustand zurücksetzen.
        stateQueue.sync {
            self.currentURL = url
            self.writtenFrames = 0
            self.isRecording = true
            self.pcmSamples.removeAll(keepingCapacity: true)
        }

        // Tap auf den Input-Node: liefert Hardware-Puffer, die wir konvertieren
        // und schreiben. bufferSize ist ein Richtwert; das System kann abweichen.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }

        // Engine vorbereiten und starten.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Tap wieder entfernen und Zustand zurücksetzen.
            inputNode.removeTap(onBus: 0)
            cleanupAfterFailure()
            throw MurmelError.audioEngineFailed("AVAudioEngine-Start fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Stoppt die Aufnahme, finalisiert die WAV und gibt die URL zurück.
    /// - Returns: URL der fertigen Datei oder nil, wenn die Aufnahme zu kurz
    ///            war, keine Frames geschrieben wurden oder ein Fehler auftrat.
    func stopRecording() -> URL? {
        // Engine stoppen und Tap entfernen (nur wenn die Engine lief).
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        // Datei schließen: AVAudioFile finalisiert die WAV beim Deallokieren
        // (Header mit Längen werden geschrieben), darum die Referenz lösen.
        audioFile = nil
        converter = nil
        targetFormat = nil

        // Zustand atomar auslesen und zurücksetzen.
        let (url, frames): (URL?, AVAudioFrameCount) = stateQueue.sync {
            let u = self.currentURL
            let f = self.writtenFrames
            self.isRecording = false
            self.currentURL = nil
            self.writtenFrames = 0
            self.pcmSamples.removeAll(keepingCapacity: false)
            return (u, f)
        }

        guard let url else { return nil }

        // Dauer aus geschriebenen Ziel-Frames berechnen (16 kHz).
        let duration = Double(frames) / targetSampleRate

        // Zu kurz / keine Frames → Datei verwerfen.
        if frames == 0 || duration < minimumDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return url
    }

    // MARK: - Interne Verarbeitung (Audio-Thread)

    /// Konvertiert einen Hardware-Eingangspuffer auf 16 kHz Mono und schreibt
    /// ihn in die WAV. Läuft auf dem Audio-Thread.
    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard
            let converter = self.converter,
            let targetFormat = self.targetFormat,
            let file = self.audioFile
        else { return }

        // Kapazität des Zielpuffers anhand des Sample-Rate-Verhältnisses
        // großzügig schätzen (+ kleiner Puffer gegen Rundung).
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let estimatedCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedCapacity
        ) else { return }

        // Der Converter zieht den Eingangspuffer genau einmal ein; danach
        // signalisieren wir "keine weiteren Daten" über .noDataNow.
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: inputBlock
        )

        // Bei echtem Fehler diesen Puffer überspringen (Aufnahme läuft weiter).
        if status == .error || conversionError != nil {
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        // In die WAV schreiben und Frame-Zähler aktualisieren.
        do {
            try file.write(from: outputBuffer)
            let written = outputBuffer.frameLength
            // Samples zusätzlich im Speicher halten (für Live-Vorschau-Snapshots).
            let n = Int(written)
            let ch0 = outputBuffer.floatChannelData?[0]
            stateQueue.sync {
                self.writtenFrames &+= written
                if let ch0 {
                    self.pcmSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: n))
                }
            }
        } catch {
            // Schreibfehler: diesen Puffer verwerfen, Aufnahme nicht abbrechen.
            return
        }
    }

    // MARK: - Aufräumen

    /// Setzt alle Aufnahme-bezogenen Felder nach einem Fehler zurück, damit ein
    /// erneuter startRecording()-Aufruf sauber beginnt.
    private func cleanupAfterFailure() {
        audioFile = nil
        converter = nil
        targetFormat = nil
        stateQueue.sync {
            self.isRecording = false
            self.currentURL = nil
            self.writtenFrames = 0
            self.pcmSamples.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Live-Vorschau-Snapshot

    /// Schreibt die bisher aufgenommenen Samples in eine temporäre WAV — ohne die
    /// laufende Aufnahme zu beeinflussen. Für die Streaming-Vorschau.
    ///
    /// - Parameter maxSeconds: Wenn > 0, wird nur das **letzte** Zeitfenster dieser Länge
    ///   transkribiert (gleitendes Fenster). Das hält jede Vorschau-Transkription auch bei
    ///   langen Diktaten schnell — die Vorschau zeigt ohnehin nur die zuletzt gesprochenen
    ///   Worte. Der FINALE Lauf nutzt weiterhin die komplette Aufnahme (separate Datei).
    func snapshotWAV(maxSeconds: Double = 0) -> URL? {
        var samples: [Float] = stateQueue.sync { pcmSamples }
        // Mindestens ~0,4 s Audio, sonst lohnt die Transkription nicht.
        guard samples.count >= Int(targetSampleRate * 0.4) else { return nil }

        // Gleitendes Fenster: nur die letzten `maxSeconds` behalten.
        if maxSeconds > 0 {
            let windowFrames = Int(targetSampleRate * maxSeconds)
            if samples.count > windowFrames {
                samples = Array(samples.suffix(windowFrames))
            }
        }

        guard
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: targetSampleRate,
                                    channels: targetChannels,
                                    interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { dst.update(from: base, count: samples.count) }
            }
        }

        let url = MurmelPaths.recordingsDir.appendingPathComponent("snap-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }
}
