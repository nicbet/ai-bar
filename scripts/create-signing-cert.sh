#!/bin/sh
# Creates a self-signed code-signing certificate in the login keychain so local builds keep a
# stable designated requirement, and macOS privacy grants survive rebuilds. The identity is shared
# by local apps (AI Bar, Cappucino, Nocchi, ...); set SIGNING_IDENTITY to use another name.
set -eu

IDENTITY="${SIGNING_IDENTITY:-Local App Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
	echo "\"$IDENTITY\" already exists."
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "Creating \"$IDENTITY\"..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
	-config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
	-name "$IDENTITY" -passout "pass:$PASSWORD" -out "$TMP/cert.p12"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "Trusting it for code signing (macOS asks for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Done. 'make bundle' signs with it from now on."
