import AVFoundation

/// Lokale Sprachausgabe (Text-to-Speech) über `AVSpeechSynthesizer`.
///
/// Liest Text mit einer deutschen Systemstimme vor — vollständig auf dem Gerät,
/// ohne Netzwerk. Wird für die „Antworten vorlesen"-Funktion (Zwei-Wege-Voice)
/// genutzt: Assistent-/Zusammenfassen-Antworten werden nach dem Einfügen laut
/// vorgelesen. Ein neuer `speak`-Aufruf stoppt eine ggf. laufende Ausgabe.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    /// Liest den übergebenen Text mit deutscher Stimme vor. Leerer Text wird ignoriert;
    /// eine laufende Ausgabe wird zuvor sofort gestoppt.
    func speak(_ text: String) {
        stop()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    /// Stoppt eine laufende Sprachausgabe sofort.
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
