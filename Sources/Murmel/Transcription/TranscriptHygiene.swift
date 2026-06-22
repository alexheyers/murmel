import Foundation

/// Erkennt typische Whisper-Halluzinationen bei (Fast-)Stille, die sonst fälschlich
/// eingefügt würden (z.B. „*Piep*", „[Musik]", Untertitel-Credits).
///
/// Bewusst KONSERVATIV: greift nur, wenn der GESAMTE Rohtext aus einem bekannten
/// Nicht-Sprach-Artefakt besteht — damit echte kurze Diktate („Vielen Dank.") NICHT
/// verloren gehen. Die Hauptarbeit macht ohnehin `whisper-cli -sns`; das hier ist das Netz.
enum TranscriptHygiene {

    /// Exakte (klein geschriebene, satzzeichen-getrimmte) Artefakt-Phrasen.
    private static let artifactPhrases: Set<String> = [
        "piep",
        "biep",
        "untertitel der amara.org-community",
        "untertitelung des zdf, 2020",
        "untertitelung des zdf",
        "untertitel im auftrag des zdf",
        "amara.org",
        "vielen dank fürs zuschauen",
        "vielen dank fürs zuschauen!"
    ]

    /// true, wenn der gesamte Text aller Wahrscheinlichkeit nach eine Halluzination ist.
    static func isLikelyHallucination(_ raw: String) -> Bool {
        // Auf Kern reduzieren: trimmen, Sternchen/Notenzeichen/Klammern abstreifen, kleinschreiben.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false } // Leeres wird woanders behandelt.

        // Nur-Klammer-Inhalt („[Musik]", „(Applaus)") → Artefakt.
        if let r = s.range(of: "^[\\[(].*[\\])]$", options: .regularExpression), r == s.startIndex..<s.endIndex {
            return true
        }
        // Nur Sternchen/Noten/Satzzeichen → Artefakt („*", „♪♪").
        if s.range(of: "^[\\s*♪♫.\\-–—]+$", options: .regularExpression) != nil {
            return true
        }

        // Umrahmende *…* und Satzzeichen entfernen, dann gegen die Phrasenliste prüfen.
        s = s.replacingOccurrences(of: "*", with: "")
             .trimmingCharacters(in: CharacterSet(charactersIn: " .!?-–—"))
             .lowercased()
        return artifactPhrases.contains(s)
    }

    /// Kollabiert pathologische Wiederholungsschleifen, in die Whisper bei längerem
    /// Audio kippen kann (z.B. „die wir sind so viele, die wir sind so viele, …" ×15).
    ///
    /// Erkennt eine unmittelbar wiederholte Wortfolge (1–6 Wörter) und ersetzt die
    /// ganze Kette durch EIN Vorkommen. Vergleich case-insensitiv und ohne Satzzeichen,
    /// damit „viele." / „viele," als gleich gelten. Konservativ:
    ///  - Phrasen (≥2 Wörter): ab 3 Wiederholungen kollabieren,
    ///  - Einzelwörter: erst ab 6 (echte Betonung wie „nein nein nein" bleibt erhalten).
    static func collapseRepetitions(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 4 else { return text }

        // Normalisierte Vergleichsform pro Wort (lowercased, Satzzeichen-Ränder weg).
        let norm = words.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:–—-…\"'»«„“”"))
        }

        var out: [String] = []
        var i = 0
        while i < words.count {
            var collapsed = false
            let maxN = min(6, (words.count - i) / 2)
            if maxN >= 1 {
                for n in stride(from: maxN, through: 1, by: -1) {
                    // Wie oft wiederholt sich das n-Gramm ab i unmittelbar?
                    var reps = 1
                    var j = i + n
                    while j + n <= words.count && Array(norm[j..<j+n]) == Array(norm[i..<i+n]) {
                        reps += 1
                        j += n
                    }
                    let threshold = n >= 2 ? 3 : 6
                    if reps >= threshold {
                        out.append(contentsOf: words[i..<i+n])  // genau EIN Vorkommen behalten
                        i = j
                        collapsed = true
                        break
                    }
                }
            }
            if !collapsed {
                out.append(words[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }
}
