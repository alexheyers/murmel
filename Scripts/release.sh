#!/usr/bin/env bash
#
# release.sh — baut Murmel.app und schnürt eine herunterladbare .dmg + .zip,
# optional als GitHub-Release.
#
# Nutzung:
#   ./Scripts/release.sh 0.1.0            # baut dist/Murmel-0.1.0.dmg + .zip
#   ./Scripts/release.sh 0.1.0 --publish  # erstellt zusätzlich ein GitHub-Release (braucht `gh`)
#
# Ergebnis: dist/Murmel-<version>.dmg und dist/Murmel-<version>.zip
#
set -euo pipefail

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "✗ Bitte Version angeben, z.B.: ./Scripts/release.sh 0.1.0" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/Murmel.app"
ZIP="dist/Murmel-$VERSION.zip"
DMG="dist/Murmel-$VERSION.dmg"

# 1) App bauen + signieren (stabile Identität, außerhalb iCloud)
echo "▶︎ Baue App …"
./Scripts/make-app.sh >/dev/null
[[ -d "$APP" ]] || { echo "✗ $APP fehlt nach Build" >&2; exit 1; }

# Saubere Kopie außerhalb iCloud (dist/ liegt unter ~/Documents → iCloud hängt
# FinderInfo/fileprovider-xattrs an, die Gatekeeper/codesign als „detritus" ablehnt).
CLEAN="$(mktemp -d)"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$CLEAN/Murmel.app"
xattr -cr "$CLEAN/Murmel.app" 2>/dev/null || true

# 2) ZIP (ditto bewahrt die Code-Signatur — wichtig fürs Gatekeeper-Verhalten)
echo "▶︎ Packe ZIP …"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$CLEAN/Murmel.app" "$ZIP"

# 3) DMG (Drag-to-Applications-Fenster)
echo "▶︎ Baue DMG …"
rm -f "$DMG"
STAGE="$(mktemp -d)"
/usr/bin/ditto "$CLEAN/Murmel.app" "$STAGE/Murmel.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Murmel $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$CLEAN"

echo ""
echo "✓ Fertig:"
echo "   $DMG"
echo "   $ZIP"
echo ""

# 4) Optional: GitHub-Release
if [[ "$PUBLISH" == "--publish" ]]; then
    command -v gh >/dev/null 2>&1 || { echo "✗ GitHub CLI 'gh' fehlt (brew install gh)" >&2; exit 1; }
    echo "▶︎ Erstelle GitHub-Release v$VERSION …"
    NOTES="Murmel $VERSION — lokales Voice-to-Text für macOS (100 % offline).

**Installation**
1. \`Murmel-$VERSION.dmg\` laden, öffnen, Murmel.app nach Programme ziehen.
2. Da die App selbst-signiert ist, einmalig die Gatekeeper-Quarantäne lösen:
   \`xattr -dr com.apple.quarantine /Applications/Murmel.app\`
   (oder Rechtsklick auf die App → Öffnen → Öffnen).
3. Murmel starten → die Ersteinrichtung lädt automatisch whisper.cpp, die Modelle und Ollama/Qwen (mit Zwischenfragen). Voraussetzung: Homebrew.
4. Bedienungshilfen-Recht erteilen, dann **fn halten und sprechen**.

Hinweis: 100 % lokal, kein Abo, kein Cloud-Upload."
    gh release create "v$VERSION" "$DMG" "$ZIP" --title "Murmel $VERSION" --notes "$NOTES"
    echo "✓ Release v$VERSION veröffentlicht."
else
    echo "Zum Veröffentlichen:  ./Scripts/release.sh $VERSION --publish   (braucht 'gh')"
fi
