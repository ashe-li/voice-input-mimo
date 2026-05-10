#!/usr/bin/env bash
# Build a distributable DMG for VoiceInputMimo.
#
# Inputs:
#   - VoiceInputMimo.app must already exist in the repo root (run `make build`
#     first, or rely on the `make dmg` target which chains build → dmg).
#
# Output:
#   - dist/VoiceInputMimo-<version>.dmg
#
# Signing: the embedded .app is signed by `make build` using the local cert
# from `make cert-setup` (or ad-hoc fallback). This DMG is NOT notarized — it
# is intended for technical users who can right-click → Open to bypass
# Gatekeeper. For public distribution, see README "Stage 2 — Notarization".
#
# Usage:
#   bash scripts/build-dmg.sh           # use timestamped version
#   VERSION=1.2.3 bash scripts/build-dmg.sh
#
# Idempotent: re-running overwrites the dmg in dist/.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="VoiceInputMimo"
readonly APP_BUNDLE="${APP_NAME}.app"
readonly APP_PATH="${REPO_ROOT}/${APP_BUNDLE}"
readonly DIST_DIR="${REPO_ROOT}/dist"

# VERSION default: derive from git short SHA + date so re-builds get distinct
# names without manual version bumps. Override with VERSION=x.y.z for releases.
readonly VERSION="${VERSION:-$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
readonly DMG_NAME="${APP_NAME}-${VERSION}.dmg"
readonly DMG_PATH="${DIST_DIR}/${DMG_NAME}"
readonly VOLUME_NAME="${APP_NAME} ${VERSION}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [ ! -d "${APP_PATH}" ]; then
    echo "❌ ${APP_BUNDLE} not found at ${APP_PATH}." >&2
    echo "   Run \`make build\` first." >&2
    exit 1
fi

# Verify the app is signed (ad-hoc or named cert is OK; unsigned is not).
if ! codesign -dv "${APP_PATH}" >/dev/null 2>&1; then
    echo "❌ ${APP_BUNDLE} is not signed. Run \`make build\` to sign it." >&2
    exit 1
fi

mkdir -p "${DIST_DIR}"

# ---------------------------------------------------------------------------
# Stage a temp folder representing the DMG layout:
#   /VoiceInputMimo.app
#   /Applications -> /Applications  (symlink so users can drag-install)
#   /README-INSTALL.txt              (Gatekeeper bypass instructions)
# ---------------------------------------------------------------------------

readonly STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

cat > "${STAGE_DIR}/README-INSTALL.txt" <<'EOF'
VoiceInputMimo — 安裝說明 / Installation

1. 把 VoiceInputMimo.app 拖進 Applications 資料夾。

2. 第一次打開時，macOS 會說「無法打開，因為 Apple 無法檢查是否含有惡意軟體」
   這是因為這個 app 沒有經過 Apple Notarization（自簽名 build）。
   解決方式：
     a. 右鍵點 VoiceInputMimo.app → 選「打開」→ 警告視窗按「打開」
        （只需做一次，之後雙擊就能用）
     b. 或進「系統設定 → 隱私權與安全性」→ 找到 VoiceInputMimo
        被擋的訊息 → 按「仍要打開」

3. 啟動後 macOS 會要求：
   - 麥克風權限（Microphone）— 必要，用來錄音
   - 輔助使用權限（Accessibility）— 必要，用來監聽 Fn 鍵

4. 還需要在本機跑 ASR engine + 一個 OpenAI-compatible LLM backend。
   請參考 GitHub README 的「依賴設定」段落。

================================================================================

VoiceInputMimo — Installation (English)

1. Drag VoiceInputMimo.app to the Applications folder.

2. On first launch, macOS will say "VoiceInputMimo can't be opened because
   Apple cannot check it for malicious software." This is because the build
   is not Apple-notarized (self-signed only).
   Fix:
     a. Right-click VoiceInputMimo.app → Open → click "Open" in the dialog
        (one-time; subsequent launches work normally with double-click)
     b. Or System Settings → Privacy & Security → find the blocked app
        message → click "Open Anyway"

3. The app will request Microphone and Accessibility permissions on first run.

4. You also need a local ASR engine and an OpenAI-compatible LLM backend
   running on this machine. See the project README for setup instructions.
EOF

# ---------------------------------------------------------------------------
# Build the DMG.
# `hdiutil create -srcfolder` makes a read-only compressed UDZO image.
# -fs HFS+ ensures wide compatibility with older macOS versions.
# ---------------------------------------------------------------------------

rm -f "${DMG_PATH}"

hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${DMG_PATH}"

# Sign the DMG itself with the same identity as the embedded .app, so the
# whole package has consistent signature when Gatekeeper inspects it. We pull
# the identity from the .app rather than re-deriving from the keychain so
# they stay in sync.
# Parse the leaf Authority line. `sub(/^[^=]+=/, "")` strips only the first
# `=`-prefix so cert CNs containing `=` (e.g. `CN=foo=bar`) survive intact.
# The `exit` on first match takes the leaf cert (Authority lines are ordered
# leaf → intermediate → root in `codesign -dvv` output).
SIGN_IDENTITY="$(codesign -dvv "${APP_PATH}" 2>&1 | awk '/Authority=/ {sub(/^[^=]+=/, ""); print; exit}')"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ "${SIGN_IDENTITY}" != "-" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}" 2>/dev/null || \
        echo "⚠️  Failed to sign DMG with '${SIGN_IDENTITY}' — DMG is still usable, just unsigned."
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

DMG_SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"

echo ""
echo "✅ DMG built: ${DMG_PATH}"
echo "   Volume: ${VOLUME_NAME}"
echo "   Size:   ${DMG_SIZE}"
echo "   Signed: ${SIGN_IDENTITY}"
echo ""
echo "Next steps:"
echo "  • Smoke test: open '${DMG_PATH}' and verify drag-to-install works"
echo "  • Upload as a GitHub Release asset"
echo "  • Link from README under \"Download\""
