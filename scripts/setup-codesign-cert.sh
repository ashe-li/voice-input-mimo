#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing cert in login keychain
# so codesign produces a stable bundle hash across rebuilds. Without this,
# `codesign --force --sign -` (ad-hoc) generates a fresh hash every build,
# and macOS treats each install as a new app — TCC permissions
# (Microphone, Fn-key Accessibility) get revoked on every rebuild.
#
# Idempotent. Re-run is safe (skips if cert already exists).
#
# Usage: bash scripts/setup-codesign-cert.sh
#
# After this runs once, `make build` / `make install` will pick up the
# named identity automatically (Makefile's SIGNARG falls back to ad-hoc
# only when this cert is absent).

set -euo pipefail

CERT_NAME="${CERT_NAME:-VoiceInputMimo Local}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "✅ Cert '$CERT_NAME' already exists in login keychain."
    echo "   TCC permissions persist across rebuilds — no re-grant needed."
    exit 0
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CERT_NAME
O = Local Development
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = CA:false
EOF

echo "→ Generating RSA-2048 key + self-signed cert (10-year validity)..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -config "$TMPDIR/cert.cnf" \
    -extensions v3_req \
    > /dev/null 2>&1

echo "→ Importing key + cert into login keychain..."
# Skip PKCS#12 entirely. OpenSSL 3.x's .p12 export (even with -legacy) has
# private-key-pairing quirks under macOS `security import` — the cert
# arrives but it's not paired with the key, so `find-identity` returns 0.
# Importing key + cert as separate PEMs sidesteps the whole algorithm
# dance and produces a properly paired identity.
security import "$TMPDIR/key.pem" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -A > /dev/null
security import "$TMPDIR/cert.pem" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -A > /dev/null

# Verify the import worked end-to-end (private key + codesign access).
if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "❌ Import succeeded but identity not found — keychain may need unlock." >&2
    echo "   Try: security unlock-keychain $KEYCHAIN" >&2
    exit 1
fi

cat <<EOF

✅ Cert '$CERT_NAME' created.

What changed:
  • codesign now signs with this stable identity instead of ad-hoc
  • Bundle hash is identical across rebuilds (binary unchanged)
  • macOS TCC remembers Microphone + Accessibility grants between rebuilds

Next: \`make install\` to rebuild + reinstall with the new signature.
The first install after this will still need a one-time re-grant
(transitioning from old ad-hoc identity → new named identity).
EOF
