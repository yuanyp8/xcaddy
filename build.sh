#!/usr/bin/env bash
set -euo pipefail

# 接收架构参数，例如：bash build.sh amd64
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

log "Building payload (caddy )..."
tar -czf "${PAYLOAD_FILE}" caddy

log "Creating ${INSTALLER_NAME}..."
# 核心拼接：安装脚本 + 压缩包 = 自解压安装包
cat install.sh "${PAYLOAD_FILE}" > "${INSTALLER_NAME}"
chmod +x "${INSTALLER_NAME}"

# 清理中间文件
rm -f "${PAYLOAD_FILE}"

separator
echo "Build completed"
echo "Installer: ${INSTALLER_NAME}"
echo "Size: $(du -h "${INSTALLER_NAME}" | cut -f1)"
echo "SHA256: $(sha256sum "${INSTALLER_NAME}" | cut -d' ' -f1)"
separator