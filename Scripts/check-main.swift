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

// Slash-Befehle (Claude-Code / Terminal)
let sc = proc.process("slash context")
check(sc.text == "/context", "‚slash context' → /context  (\(sc.text))")

let scAlias = proc.process("Slash klar")
check(scAlias.text == "/clear", "‚slash klar' → /clear (deutscher Verhörer)  (\(scAlias.text))")

let scMid = proc.process("bitte slash commit ausführen")
check(scMid.text == "bitte /commit ausführen", "‚slash commit' mitten im Satz → /commit  (\(scMid.text))")

let scCustom = proc.process("slash studio")
check(scCustom.text == "/studio", "eigener Command ‚slash studio' → /studio  (\(scCustom.text))")

check(!DictationStyle.raw.usesPolish, "Roh poliert nicht")
check(DictationStyle.email.usesPolish && DictationStyle.claudePrompt.usesPolish, "andere Stile polieren")
check(DictationStyle.allCases.allSatisfy { !$0.displayName.isEmpty }, "alle Stile haben Anzeigenamen")

// Struktur-Modus (Absätze in langem Fließtext)
check(DictationStyle.structured.isStructured, "Struktur-Modus: isStructured-Flag")
check(DictationStyle.structured.usesPolish, "Struktur-Modus: poliert (Ollama)")
check(DictationStyle.structured.usesEditableInstruction, "Struktur-Modus: Instruktion editierbar")
check(!DictationStyle.structured.polishInstruction.isEmpty, "Struktur-Modus: hat Standard-Instruktion")

let polisher = OllamaPolisher(baseURL: "http://127.0.0.1:1", model: "egal")
let raw = await polisher.polish("unverändert", style: .raw, instruction: "", vocabularyHint: [])
check(raw == "unverändert", "Roh-Stil: kein Netzwerk, Text 1:1")

let fb = await polisher.polish("bitte nicht verlieren", style: .email, instruction: DictationStyle.email.polishInstruction, vocabularyHint: [])
check(fb == "bitte nicht verlieren", "Ollama unerreichbar → Fallback auf Originaltext")

let entries = [
    HistoryEntry(id: 1, timestamp: Date(), raw: "ähm das ist ein test ähm wirklich", final: "x", style: .raw, app: "Test"),
    HistoryEntry(id: 2, timestamp: Date(), raw: "noch ein satz mit vielen wörtern hier drin", final: "x", style: .raw, app: "Terminal")
]
let an = SpeechAnalyzer.analyze(entries)
check(an.dictations == 2, "Analyse: 2 Diktate erkannt")
check(an.fillers.first?.word == "ähm", "Analyse: Füllwort ähm erkannt")

// whisper-server-Vorschau: reine Logik (ohne laufenden Server testbar)
let jsonResp = #"{"text":" Dies ist ein Test.\n"}"#.data(using: .utf8)!
check(WhisperServerTranscriber.parseText(jsonResp) == "Dies ist ein Test.",
      "whisper-server: JSON {text} geparst + getrimmt")

let plainResp = " nur klartext \n".data(using: .utf8)!
check(WhisperServerTranscriber.parseText(plainResp) == "nur klartext",
      "whisper-server: Klartext-Fallback getrimmt")

let mp = WhisperServerTranscriber.multipartBody(boundary: "B", audio: Data([0x52, 0x49]), language: "de")
let mpStr = String(data: mp, encoding: .utf8) ?? ""
check(mpStr.contains("name=\"file\"; filename=\"audio.wav\"")
      && mpStr.contains("name=\"language\"\r\n\r\nde")
      && mpStr.contains("name=\"response_format\"\r\n\r\njson")
      && mpStr.hasSuffix("--B--\r\n"),
      "whisper-server: multipart-Body korrekt")

let srv = WhisperServerTranscriber(binaryPath: "/x", modelPath: "/y", language: "de", host: "127.0.0.1", port: 8771)
check(srv.inferenceURL.absoluteString == "http://127.0.0.1:8771/inference",
      "whisper-server: inferenceURL korrekt aufgebaut")

// Anti-Halluzination (Stille-Artefakte)
check(TranscriptHygiene.isLikelyHallucination("*Piep*"), "Halluzination: *Piep* erkannt")
check(TranscriptHygiene.isLikelyHallucination("[Musik]"), "Halluzination: [Musik] erkannt")
check(TranscriptHygiene.isLikelyHallucination("Untertitel der Amara.org-Community"), "Halluzination: Amara-Untertitel erkannt")
check(!TranscriptHygiene.isLikelyHallucination("Das ist ein echter Satz."), "Echter Satz NICHT als Halluzination")
check(!TranscriptHygiene.isLikelyHallucination("Vielen Dank."), "‚Vielen Dank.' bleibt erhalten (kein Falsch-Filter)")

// De-Loop: Whisper-Wiederholungsschleifen kollabieren
let loop = "Wir haben viel gesammelt. die wir sind so viele, die wir sind so viele, die wir sind so viele, die wir sind so viele, die wir sind so viele."
let deloop = TranscriptHygiene.collapseRepetitions(loop)
check(deloop.lowercased().contains("wir haben viel gesammelt"), "De-Loop: echter Anfang bleibt erhalten")
check(!deloop.lowercased().contains("so viele, die wir sind so viele, die wir sind so viele"), "De-Loop: Schleife kollabiert  (\(deloop.count) Zeichen)")
let normal = "Das ist ein ganz normaler Satz ohne jede Wiederholung darin."
check(TranscriptHygiene.collapseRepetitions(normal) == normal, "De-Loop: normaler Satz unverändert")
let emphasis = "nein nein nein war meine Antwort"
check(TranscriptHygiene.collapseRepetitions(emphasis) == emphasis, "De-Loop: 3x Einzelwort-Betonung bleibt (Schwelle 6)")

// Gesprächs-Modus: reine Logik
let convMsgs = ConversationEngine.assemble([["role":"user","content":"Hallo"]])
check(convMsgs.first?["role"] == "system", "Gespräch: erste Nachricht ist System-Prompt")
check(convMsgs.count == 2 && convMsgs.last?["content"] == "Hallo", "Gespräch: Verlauf korrekt angehängt")
check(!ConversationEngine.systemPrompt().isEmpty, "Gespräch: System-Prompt vorhanden")
let spoken = ConversationEngine.spokenClean("Das ist **wichtig** und `code` 😀\nmehr.")
check(!spoken.contains("*") && !spoken.contains("`") && spoken.contains("wichtig"),
      "Gespräch: spokenClean entfernt Markdown/Emoji  (\(spoken))")
check(PiperSpeaker.piperArguments(modelPath: "M.onnx", outputWav: "out.wav")
      == ["-m", "piper", "-m", "M.onnx", "-f", "out.wav"], "Piper: CLI-Argumente korrekt")
// RAG-Gespräch: Kontext wird als System-Block VOR der Frage eingefügt
let ragMsgs = ConversationEngine.assembleForChat(history: [], context: "Projekt X startet im Juli.", user: "Wann startet Projekt X?")
check(ragMsgs.count == 3 && ragMsgs[0]["role"] == "system" && ragMsgs[1]["role"] == "system"
      && (ragMsgs[1]["content"] ?? "").contains("Projekt X startet") && ragMsgs[2]["role"] == "user",
      "RAG-Gespräch: Kontext-Block korrekt vor der Frage")
let noCtx = ConversationEngine.assembleForChat(history: [], context: "   ", user: "Hi")
check(noCtx.count == 2, "RAG-Gespräch: leerer Kontext → kein Block")

// Notion-Client: Parser (ohne Netz)
let nSearch = #"{"results":[{"id":"abc","properties":{"Name":{"type":"title","title":[{"plain_text":"Architektur-Bausteine"}]}}}]}"#.data(using: .utf8)!
let titles = NotionClient.parseSearchTitles(nSearch)
check(titles.count == 1 && titles[0].id == "abc" && titles[0].title == "Architektur-Bausteine",
      "Notion: Suchtreffer (id+Titel) geparst")
let nBlocks = #"{"results":[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"Hallo Welt"}]}},{"type":"heading_2","heading_2":{"rich_text":[{"plain_text":"Abschnitt"}]}}]}"#.data(using: .utf8)!
let txt = NotionClient.extractPlainText(fromBlocks: nBlocks)
check(txt.contains("Hallo Welt") && txt.contains("Abschnitt"), "Notion: Block-Klartext extrahiert  (\(txt.replacingOccurrences(of: "\n", with: " | ")))")
check(NotionClient(token: "  ").isConfigured == false, "Notion: leerer Token → nicht konfiguriert")

// Auto-Modus: App → Stil
check(AppStyleMapper.style(forBundleId: "com.apple.Terminal", name: nil) == .raw, "Auto-Modus: Terminal → roh")
check(AppStyleMapper.style(forBundleId: "com.apple.mail", name: nil) == .email, "Auto-Modus: Mail → email")
check(AppStyleMapper.style(forBundleId: "com.unknown.app", name: "Foo") == nil, "Auto-Modus: Unbekannt → nil")
check(AppStyleMapper.style(forBundleId: "net.whatsapp.WhatsApp", name: nil) == .structured, "Auto-Modus: WhatsApp → strukturiert")
check(AppStyleMapper.style(forBundleId: nil, name: "Telegram") == .structured, "Auto-Modus: Telegram (Name) → strukturiert")

print(failures == 0 ? "\nALLE CHECKS GRÜN" : "\n\(failures) CHECK(S) FEHLGESCHLAGEN")
exit(failures == 0 ? 0 : 1)
