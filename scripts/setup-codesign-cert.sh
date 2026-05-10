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

# No -v flag: self-signed certs always fail trust validation
# (CSSMERR_TP_NOT_TRUSTED), but codesign-by-name doesn't care about trust.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CERT_NAME"; then
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

echo "→ Bundling key + cert into PKCS#12..."
# macOS `security import` only creates a paired identity (cert + private key
# linked together) when the input is PKCS#12. Importing key.pem + cert.pem
# as separate PEMs uploads both blobs but does NOT pair them, so
# `find-identity` returns 0 even though the cert is visible.
#
# PKCS#12 algorithm dance for macOS Security framework compatibility:
#   - Modern OpenSSL 3.x defaults (PBES2 / AES-256 / SHA-256) → macOS
#     `security import` fails with "MAC verification failed".
#   - `-legacy` (RC2-40) → OpenSSL 3.6+ can't read its own output back,
#     and macOS imports the cert WITHOUT the private key (orphan identity).
#   - PBE-SHA1-3DES + macalg sha1 → the only combo macOS Keychain
#     reliably accepts on macOS 14+ while still being decryptable by
#     OpenSSL 3.6+.
# Empty passwords trigger MAC verification quirks, so use a fixed
# throwaway password (the .p12 is deleted immediately after import).
P12_PATH="$TMPDIR/identity.p12"
P12_PASS="codesign-throwaway"
openssl pkcs12 -export \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -name "$CERT_NAME" \
    -out "$P12_PATH" \
    -passout "pass:$P12_PASS" \
    > /dev/null 2>&1

echo "→ Importing PKCS#12 into login keychain..."
# NO -T -A flags here. On macOS 26+, combining `-T /usr/bin/codesign -A` with
# PKCS#12 import silently drops the private key — only the cert + public key
# arrive, no paired identity is created, and `find-identity` returns 0.
# Minimal-flag import correctly produces "1 identity imported.".
#
# Trade-off: without `-T -A`, the first `codesign --sign "$CERT_NAME"` call
# will trigger a one-time SecurityAgent dialog asking permission to use the
# private key. Click "Always Allow" once and subsequent codesign runs are
# silent. (Power users can pre-grant via `security set-key-partition-list`,
# but that requires the macOS login password — we keep the script
# non-interactive and let codesign handle the prompt naturally.)
security import "$P12_PATH" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" > /dev/null

# Verify the import worked end-to-end (private key + codesign access).
# Same -v caveat applies here.
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "❌ Import succeeded but identity not found." >&2
    echo "   Common causes:" >&2
    echo "     • Keychain locked: security unlock-keychain $KEYCHAIN" >&2
    echo "     • Search list polluted: security list-keychains -s $KEYCHAIN /Library/Keychains/System.keychain" >&2
    exit 1
fi

cat <<EOF

✅ Cert '$CERT_NAME' created.

What changed:
  • codesign now signs with this stable identity instead of ad-hoc
  • Bundle hash is identical across rebuilds (binary unchanged)
  • macOS TCC remembers Microphone + Accessibility grants between rebuilds

⚠️  First-run prompts you'll see (one-time each):
  1. SecurityAgent dialog: "codesign wants to use a private key..."
     → click **Always Allow** so future builds run silently.
  2. macOS TCC: re-grant Microphone + Accessibility on next launch
     (transitioning from old ad-hoc identity → new named identity).

Next: \`make install\` to rebuild + reinstall with the new signature.
EOF
