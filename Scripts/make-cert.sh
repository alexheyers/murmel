#!/usr/bin/env bash
#
# make-cert.sh — erstellt eine stabile, selbst-signierte Code-Signing-Identität
# im Login-Schlüsselbund. Damit signiert make-app.sh die App immer mit derselben
# Identität → macOS-Rechte (Mikrofon, Bedienungshilfen) überleben Rebuilds.
#
# Einmalig ausführen. Idempotent: vorhandenes Zertifikat wird nicht ersetzt.
#
set -euo pipefail

CERT_NAME="Murmel Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✓ Zertifikat ‚$CERT_NAME' existiert bereits."
    exit 0
fi

TMP="$(mktemp -d)"
cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Murmel Code Signing
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1

# -legacy ist nötig: OpenSSL 3 schreibt sonst ein PKCS12-Format, das Apples
# `security import` nicht lesen kann ("MAC verification failed").
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:murmel >/dev/null 2>&1

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "murmel" -T /usr/bin/codesign -A

rm -rf "$TMP"
echo "✓ Zertifikat ‚$CERT_NAME' erstellt und in den Login-Schlüsselbund importiert."
