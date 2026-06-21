import Foundation

/// Ergebnis der Sprachanalyse über die Diktat-Historie.
struct SpeechAnalysis: Equatable {
    var dictations: Int = 0
    var totalWords: Int = 0
    var avgWords: Double = 0
    var avgSentenceLength: Double = 0
    var longestWords: Int = 0
    var fillers: [(word: String, count: Int)] = []
    var topWords: [(word: String, count: Int)] = []
    var apps: [(app: String, count: Int)] = []
    var tips: [String] = []

    static func == (lhs: SpeechAnalysis, rhs: SpeechAnalysis) -> Bool {
        lhs.dictations == rhs.dictations && lhs.totalWords == rhs.totalWords
    }
}

/// Analysiert, *wie* gesprochen wird — auf Basis der Whisper-Rohtexte im Verlauf.
/// Reine Funktion, ohne Seiteneffekte (gut testbar).
enum SpeechAnalyzer {

    /// Typische deutsche Füllwörter, die man beim Sprechen oft unbewusst nutzt.
    static let fillerWords = ["ähm", "äh", "halt", "quasi", "sozusagen",
                              "irgendwie", "eigentlich", "also", "genau", "ne"]

    /// Häufige Wörter, die für die „Top-Begriffe" ignoriert werden.
    private static let stopWords: Set<String> = [
        "der","die","das","und","ich","ist","nicht","ein","eine","einen","mit","auf",
        "für","den","dem","des","im","in","zu","zum","zur","von","es","auch","aber",
        "dass","wenn","wie","was","wir","du","er","sie","man","mir","mich","dir","dich",
        "so","da","dann","noch","schon","mal","ja","nein","oder","als","am","an","bei",
        "nur","sehr","mehr","hier","jetzt","wird","haben","hat","habe","kann","muss",
        "this","that","the","and","is","to","of","a","in","it","you","we","for"
    ]

    static func analyze(_ entries: [HistoryEntry]) -> SpeechAnalysis {
        // Wir analysieren den ROHTEXT — das ist, was tatsächlich gesprochen wurde.
        let texts = entries.map { $0.raw.lowercased() }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var a = SpeechAnalysis()
        guard !texts.isEmpty else {
            a.tips = ["Noch keine Diktate — sprich ein paar Sätze, dann erscheint hier deine Analyse."]
            return a
        }

        var allWords: [String] = []
        var sentenceCount = 0
        var perDictationWordCounts: [Int] = []

        for text in texts {
            let words = tokenize(text)
            allWords.append(contentsOf: words)
            perDictationWordCounts.append(words.count)
            // Sätze grob über Satzendzeichen zählen (mind. 1 pro Diktat).
            let sentences = text.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            sentenceCount += max(1, sentences.count)
        }

        a.dictations = texts.count
        a.totalWords = allWords.count
        a.avgWords = Double(allWords.count) / Double(texts.count)
        a.avgSentenceLength = sentenceCount > 0 ? Double(allWords.count) / Double(sentenceCount) : 0
        a.longestWords = perDictationWordCounts.max() ?? 0

        // Füllwörter zählen.
        var counts: [String: Int] = [:]
        for w in allWords { counts[w, default: 0] += 1 }
        a.fillers = fillerWords
            .map { ($0, counts[$0] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }

        // Top-Begriffe (ohne Stopwords/Füllwörter, min. 4 Zeichen).
        let fillerSet = Set(fillerWords)
        a.topWords = counts
            .filter { $0.key.count >= 4 && !stopWords.contains($0.key) && !fillerSet.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { ($0.key, $0.value) }

        // Wo wurde diktiert? (App-Verteilung)
        var appCounts: [String: Int] = [:]
        for e in entries {
            let name = e.app.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { appCounts[name, default: 0] += 1 }
        }
        a.apps = appCounts.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }

        a.tips = buildTips(a)
        return a
    }

    // MARK: - Helpers

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "äöüß")))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func buildTips(_ a: SpeechAnalysis) -> [String] {
        var tips: [String] = []
        let fillerTotal = a.fillers.reduce(0) { $0 + $1.count }
        if let top = a.fillers.first, top.count >= 3 {
            tips.append("Du nutzt \"\(top.word)\" oft (\(top.count)x). Mit den Stilen E-Mail oder Claude-Prompt putzt Murmel solche Füllwörter automatisch raus.")
        }
        if a.avgSentenceLength >= 25 {
            tips.append("Deine Sätze sind im Schnitt lang (\(Int(a.avgSentenceLength)) Wörter). Kürzere Sätze diktieren = klarere Texte.")
        }
        if fillerTotal == 0 {
            tips.append("Stark: kaum Füllwörter in deinen Diktaten. Sehr sauberes Sprechen.")
        }
        if a.dictations >= 10 {
            tips.append("Schon \(a.dictations) Diktate — je mehr du sprichst, desto aussagekräftiger wird diese Analyse.")
        }
        if tips.isEmpty {
            tips.append("Sprich weiter — ab ein paar Diktaten zeigt Murmel hier echte Muster.")
        }
        return tips
    }
}
