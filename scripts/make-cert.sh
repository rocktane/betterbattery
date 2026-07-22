#!/bin/bash
# Creates the self-signed code-signing certificate used to sign the app and the
# privileged helper. The helper pins this cert's SHA-1 (see Makefile) to
# validate XPC clients, so both binaries must be signed with it.
#
# Usage: make-cert.sh [name]
#   name           certificate common name (default: "BetterBattery Signing")
#
# Environment:
#   CERT_KEYCHAIN  target keychain (default: login keychain). CI passes its
#                  temporary build keychain here.
set -euo pipefail

NAME="${1:-BetterBattery Signing}"
KEYCHAIN="${CERT_KEYCHAIN:-}"
P12_PASS="betterbattery-cert"
# System LibreSSL: Homebrew OpenSSL 3 produces p12 files that `security import` rejects
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
  echo "Certificate '$NAME' already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

"$OPENSSL" pkcs12 -export -name "$NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$P12_PASS" -out "$TMP/cert.p12"

security import "$TMP/cert.p12" ${KEYCHAIN:+-k "$KEYCHAIN"} \
  -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

echo "Created certificate '$NAME'${KEYCHAIN:+ in $KEYCHAIN}."
