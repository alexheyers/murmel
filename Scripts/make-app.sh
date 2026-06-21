#!/usr/bin/env bash
#
# make-app.sh — baut Murmel und verpackt das Binary zu einer macOS .app.
#
# WICHTIG: Das Bundle wird in einem TEMP-Ordner (außerhalb iCloud) zusammengebaut
# und signiert. Grund: Liegt das Projekt unter ~/Documents (iCloud), hängt der
# File-Provider geschützte Attribute (com.apple.FinderInfo / fileprovider) an den
# .app-Ordner, die codesign als „resource fork / detritus" ablehnt und die sich
# nicht entfernen lassen. Im TEMP-Ordner passiert das nicht.
#
# Ergebnis: dist/Murmel.app (fertig signiert mit stabiler Identität → macOS-Rechte
# bleiben über Rebuilds erhalten). Direkt installierbar: dist/Murmel.app → /Applications.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN_NAME="Murmel"
DIST="dist/Murmel.app"

echo "▶︎ Release-Build…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "✗ Binary nicht gefunden: $BIN_PATH" >&2
    exit 1
fi

# Bundle in TEMP zusammenbauen (kein iCloud, keine fileprovider-xattrs).
BUILD_DIR="$(mktemp -d)"
APP="$BUILD_DIR/Murmel.app"

echo "▶︎ App-Bundle zusammenbauen (temp, außerhalb iCloud)…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/ditto --norsrc --noextattr --noqtn "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
/usr/bin/ditto --norsrc --noextattr --noqtn "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP" 2>/dev/null || true

# Stabile Signatur-Identität bevorzugen (überlebt Rebuilds → macOS-Rechte bleiben erhalten).
SIGN_ID="Murmel Code Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "▶︎ Signatur mit stabiler Identität ‚$SIGN_ID'…"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "▶︎ Ad-hoc-Signatur (kein stabiles Zertifikat — siehe Scripts/make-cert.sh)…"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "✓ Signatur verifiziert"

# Fertig signiertes Bundle nach dist/ übertragen (ditto erhält die Signatur).
echo "▶︎ Nach $DIST übertragen…"
rm -rf "$DIST"
mkdir -p dist
/usr/bin/ditto "$APP" "$DIST"
rm -rf "$BUILD_DIR"

echo ""
echo "✓ Fertig: $DIST"
echo ""
echo "Installieren:"
echo "  cp -R \"$DIST\" /Applications/ && open /Applications/Murmel.app"
