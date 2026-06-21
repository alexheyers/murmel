#!/usr/bin/env bash
#
# make-app.sh — baut Murmel und verpackt das Binary zu einer macOS .app.
#
# Ergebnis: dist/Murmel.app  (ad-hoc signiert, damit die macOS-Rechte
# Mikrofon + Bedienungshilfen stabil an der App-Identität hängen).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/Murmel.app"
BIN_NAME="Murmel"

echo "▶︎ Release-Build…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "✗ Binary nicht gefunden: $BIN_PATH" >&2
    exit 1
fi

echo "▶︎ App-Bundle zusammenbauen…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# ditto statt cp: kopiert ohne Resource-Forks/Quarantäne (sauberer fürs Signieren).
/usr/bin/ditto --norsrc --noextattr --noqtn "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ Erweiterte Attribute strippen (verhindert codesign ‚detritus'-Fehler)…"
xattr -cr "$APP" 2>/dev/null || true
# macOS Sequoia/Tahoe: geschütztes com.apple.provenance entfernen, sonst scheitert codesign.
xattr -rd com.apple.provenance "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true

# Stabile Signatur-Identität bevorzugen (überlebt Rebuilds → macOS-Rechte bleiben erhalten).
# Fällt auf Ad-hoc zurück, falls das Zertifikat fehlt (dann muss das Recht je Build neu erteilt werden).
SIGN_ID="Murmel Code Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "▶︎ Signatur mit stabiler Identität ‚$SIGN_ID'…"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "▶︎ Ad-hoc-Signatur (kein stabiles Zertifikat gefunden — siehe Scripts/make-cert.sh)…"
    codesign --force --deep --sign - "$APP"
fi

echo ""
echo "✓ Fertig: $APP"
echo ""
echo "Nächste Schritte:"
echo "  1) cp -R \"$APP\" /Applications/"
echo "  2) open /Applications/Murmel.app"
echo "  3) Beim ersten Start Mikrofon + Bedienungshilfen erlauben."
echo "     (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Murmel ✓)"
