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
    Sources/Murmel/Features/VoiceCommandProcessor.swift \
    Sources/Murmel/Polish/OllamaPolisher.swift \
    "$TMP/main.swift"

echo "--- Murmel Selbsttest ---"
"$OUT"
