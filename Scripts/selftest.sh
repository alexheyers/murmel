#!/usr/bin/env bash
#
# selftest.sh — verifiziert die reine Murmel-Logik OHNE Xcode.
# (Die XCTest/Swift-Testing-Suite in Tests/ braucht volles Xcode;
#  dieser Check kompiliert die echten Quelldateien standalone mit swiftc.)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
OUT="$TMP/murmelcheck"
# swiftc verlangt Top-Level-Code in einer Datei namens main.swift.
cp Scripts/check-main.swift "$TMP/main.swift"

swiftc -o "$OUT" \
    Sources/Murmel/Core/Models.swift \
    Sources/Murmel/Core/Protocols.swift \
    Sources/Murmel/Core/Paths.swift \
    Sources/Murmel/Core/Log.swift \
    Sources/Murmel/Features/VoiceCommandProcessor.swift \
    Sources/Murmel/Features/SpeechAnalyzer.swift \
    Sources/Murmel/Features/AppStyleMapper.swift \
    Sources/Murmel/Features/ConversationEngine.swift \
    Sources/Murmel/Features/PiperSpeaker.swift \
    Sources/Murmel/Polish/OllamaPolisher.swift \
    Sources/Murmel/Transcription/WhisperServerTranscriber.swift \
    Sources/Murmel/Transcription/TranscriptHygiene.swift \
    "$TMP/main.swift"

echo "--- Murmel Selbsttest ---"
"$OUT"
