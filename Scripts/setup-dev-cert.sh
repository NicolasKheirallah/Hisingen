#!/bin/sh
set -e

CERT_NAME="Hisingen Development"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if [ ! -f "$KEYCHAIN" ]; then
    KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

if security find-identity -p codesigning | grep -q "\"$CERT_NAME\""; then
    echo "✅ Found existing certificate \"$CERT_NAME\"."
    exit 0
fi

echo "==> Generating local self-signed code signing certificate \"$CERT_NAME\"..."

TMP_DIR="$(mktemp -d /tmp/hisingen-cert.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat << 'EOF' > "$TMP_DIR/cert.cnf"
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
prompt              = no
x509_extensions     = v3_req

[ req_distinguished_name ]
CN                  = Hisingen Development

[ v3_req ]
keyUsage            = critical, digitalSignature
extendedKeyUsage    = critical, 1.3.6.1.5.5.7.3.3
basicConstraints    = critical, CA:FALSE
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 \
    -config "$TMP_DIR/cert.cnf" >/dev/null 2>&1

# Export with -legacy for modern OpenSSL 3.x / macOS Security compatibility
openssl pkcs12 -export -legacy \
    -out "$TMP_DIR/identity.p12" \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -passout pass:secret \
    -name "$CERT_NAME" >/dev/null 2>&1 || \
openssl pkcs12 -export \
    -out "$TMP_DIR/identity.p12" \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -passout pass:secret \
    -name "$CERT_NAME" >/dev/null 2>&1

echo "==> Importing \"$CERT_NAME\" into login keychain..."
security import "$TMP_DIR/identity.p12" -k "$KEYCHAIN" -P "secret" -T /usr/bin/codesign >/dev/null 2>&1

# Set key partition list so codesign does not prompt for keychain authorization
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "✅ Successfully installed local code signing certificate \"$CERT_NAME\"."
echo "   Builds signed with this certificate have a persistent identity,"
echo "   so macOS will remember Keychain & Accessibility permissions across rebuilds."
