import Foundation

// Standalone-Checks der reinen Logik (ohne Xcode/XCTest).
// Wird von Scripts/selftest.sh mit den echten Quelldateien kompiliert.

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("✅ \(msg)") } else { print("❌ \(msg)"); failures += 1 }
}

let proc = VoiceCommandProcessor()

let p = proc.process("das ist ein Test punkt")
check(!p.aborted && p.text.hasSuffix("."), "‚punkt' → .  (\(p.text))")

let nl = proc.process("erste Zeile neue Zeile zweite Zeile")
check(nl.text.contains("\n"), "‚neue Zeile' → \\n")

let ab = proc.process("ach quatsch abbrechen")
check(ab.aborted, "‚abbrechen' → aborted")

let pt = proc.process("ein ganz normaler Satz ohne Befehle")
check(!pt.aborted && pt.text == "ein ganz normaler Satz ohne Befehle", "Passthrough unverändert")

check(!DictationStyle.raw.usesPolish, "Roh poliert nicht")
check(DictationStyle.email.usesPolish && DictationStyle.claudePrompt.usesPolish, "andere Stile polieren")
check(DictationStyle.allCases.allSatisfy { !$0.displayName.isEmpty }, "alle Stile haben Anzeigenamen")

let polisher = OllamaPolisher(baseURL: "http://127.0.0.1:1", model: "egal")
let raw = await polisher.polish("unverändert", style: .raw, instruction: "", vocabularyHint: [])
check(raw == "unverändert", "Roh-Stil: kein Netzwerk, Text 1:1")

let fb = await polisher.polish("bitte nicht verlieren", style: .email, instruction: DictationStyle.email.polishInstruction, vocabularyHint: [])
check(fb == "bitte nicht verlieren", "Ollama unerreichbar → Fallback auf Originaltext")

let entries = [
    HistoryEntry(id: 1, timestamp: Date(), raw: "ähm das ist ein test ähm wirklich", final: "x", style: .raw),
    HistoryEntry(id: 2, timestamp: Date(), raw: "noch ein satz mit vielen wörtern hier drin", final: "x", style: .raw)
]
let an = SpeechAnalyzer.analyze(entries)
check(an.dictations == 2, "Analyse: 2 Diktate erkannt")
check(an.fillers.first?.word == "ähm", "Analyse: Füllwort ähm erkannt")

print(failures == 0 ? "\nALLE CHECKS GRÜN" : "\n\(failures) CHECK(S) FEHLGESCHLAGEN")
exit(failures == 0 ? 0 : 1)
