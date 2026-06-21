import Testing
@testable import Murmel

@Suite("Sprachbefehle")
struct VoiceCommandTests {
    let proc = VoiceCommandProcessor()

    @Test("‚punkt' wird zu .")
    func punctuation() {
        let r = proc.process("das ist ein Test punkt")
        #expect(r.aborted == false)
        #expect(r.text.hasSuffix("."))
    }

    @Test("‚neue Zeile' wird zu Zeilenumbruch")
    func newline() {
        let r = proc.process("erste Zeile neue Zeile zweite Zeile")
        #expect(r.text.contains("\n"))
    }

    @Test("‚abbrechen' verwirft das Diktat")
    func abort() {
        let r = proc.process("ach quatsch abbrechen")
        #expect(r.aborted == true)
    }

    @Test("normaler Satz bleibt unverändert")
    func passthrough() {
        let r = proc.process("ein ganz normaler Satz ohne Befehle")
        #expect(r.aborted == false)
        #expect(r.text == "ein ganz normaler Satz ohne Befehle")
    }
}

@Suite("Stil-Modi")
struct DictationStyleTests {
    @Test("Roh poliert nicht")
    func rawNoPolish() {
        #expect(DictationStyle.raw.usesPolish == false)
    }

    @Test("andere Stile polieren")
    func othersPolish() {
        #expect(DictationStyle.email.usesPolish)
        #expect(DictationStyle.claudePrompt.usesPolish)
        #expect(DictationStyle.codeComment.usesPolish)
    }

    @Test("jeder Stil hat einen Anzeigenamen")
    func displayNames() {
        for style in DictationStyle.allCases {
            #expect(style.displayName.isEmpty == false)
        }
    }
}

@Suite("Politur-Fallback")
struct OllamaPolisherTests {
    @Test("Roh-Stil gibt Text ohne Netzwerk 1:1 zurück")
    func rawReturnsInput() async {
        let polisher = OllamaPolisher(baseURL: "http://127.0.0.1:1", model: "egal")
        let input = "unveränderter Text"
        let out = await polisher.polish(input, style: .raw, instruction: "", vocabularyHint: [])
        #expect(out == input)
    }

    @Test("nicht erreichbares Ollama → Fallback auf Originaltext")
    func fallbackOnUnreachable() async {
        let polisher = OllamaPolisher(baseURL: "http://127.0.0.1:1", model: "egal")
        let input = "bitte nicht verlieren"
        let out = await polisher.polish(input, style: .email, instruction: DictationStyle.email.polishInstruction, vocabularyHint: [])
        #expect(out == input)
    }
}
