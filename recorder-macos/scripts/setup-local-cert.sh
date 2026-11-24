#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="Local Meeting Recorder"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "Code signing certificate '$CERT_NAME' already exists."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/cert.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
x509_extensions    = v3_code_sign

[ req_dn ]
CN = ${CERT_NAME}

[ v3_code_sign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/key.pem" \
  -out "$TMP_DIR/cert.pem" \
  -days 3650 \
  -config "$TMP_DIR/cert.cfg"

openssl pkcs12 -export \
  -inkey "$TMP_DIR/key.pem" \
  -in "$TMP_DIR/cert.pem" \
  -out "$TMP_DIR/cert.p12" \
  -passout pass:local-meeting-recorder

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP_DIR/cert.p12" -k "$LOGIN_KEYCHAIN" -P local-meeting-recorder -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP_DIR/cert.pem"

echo "Installed and trusted '$CERT_NAME' in $LOGIN_KEYCHAIN."
echo "Re-run 'npm run build:swift' so MeetingRecorder.app uses it."
