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
}
