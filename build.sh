#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-amd64}"
INSTALLER_NAME="caddy-alidns-linux-${ARCH}.run"
PAYLOAD_FILE="payload.tar.gz"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

log "Checking project structure..."
[[ -f "install.sh" ]] || err "Missing install.sh"
[[ -f "caddy" ]] || err "Missing caddy binary"
grep -q '__PAYLOAD_BELOW__' install.sh || err "install.sh is missing __PAYLOAD_BELOW__ marker"

log "Cleaning old artifacts..."
rm -f "$PAYLOAD_FILE" "$INSTALLER_NAME"

# 🚀 核心修复：强制统一换行符为 Unix 格式 (LF)，彻底解决 Windows CRLF 导致的匹配失败
log "Sanitizing install.sh line endings..."
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix install.sh
else
    # 如果没有 dos2unix 命令，用 sed 强制剥除 \r
    sed -i 's/\r$//' install.sh
fi

# 🚀 核心修复：确保文件末尾有且仅有一个换行符，让 __PAYLOAD_BELOW__ 独占一行
if [ "$(tail -c 1 install.sh | wc -l)" -eq 0 ]; then
    log "Appending missing newline at end of install.sh..."
    echo "" >> install.sh
fi

log "Building payload (only caddy binary)..."
tar -czf "${PAYLOAD_FILE}" caddy

log "Creating ${INSTALLER_NAME}..."
cat install.sh "${PAYLOAD_FILE}" > "${INSTALLER_NAME}"
chmod +x "${INSTALLER_NAME}"

rm -f "${PAYLOAD_FILE}"

echo "=========================================="
echo "Build completed"
echo "Installer: ${INSTALLER_NAME}"
echo "Size: $(du -h "${INSTALLER_NAME}" | cut -f1)"
echo "SHA256: $(sha256sum "${INSTALLER_NAME}" | cut -d' ' -f1)"
echo "=========================================="