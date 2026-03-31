#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${ROOT_DIR}/.payload-build"
INSTALLER_STUB="${ROOT_DIR}/install.sh"
README_FILE="${ROOT_DIR}/README.md"

ARCH=""
BINARY=""
OUTPUT=""
VERSION=""

log() {
    printf '[INFO] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  ./build.sh --arch amd64
  ./build.sh --arch arm64 --binary ./dist/caddy-linux-arm64

参数:
  --arch ARCH       目标架构，支持 amd64 / arm64
  --binary PATH     指定已经构建好的 Caddy 二进制路径
  --output PATH     指定输出 .run 文件路径
  --version VALUE   附加写入 manifest.txt 的版本描述
  -h, --help        显示帮助

说明:
  1. 该脚本不会编译 Caddy，只负责把已经构建好的二进制打成离线 .run。
  2. 默认按以下顺序寻找二进制:
     - ./caddy
     - ./dist/caddy-linux-<arch>
     - ./bin/<arch>/caddy
     - ./caddy-linux-<arch>
EOF
}

normalize_arch() {
    case "${1:-}" in
        amd64|x86_64)
            printf 'amd64\n'
            ;;
        arm64|aarch64)
            printf 'arm64\n'
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_binary() {
    local candidate

    if [[ -n "${BINARY}" ]]; then
        [[ -f "${BINARY}" ]] || die "指定的二进制不存在: ${BINARY}"
        printf '%s\n' "${BINARY}"
        return 0
    fi

    for candidate in \
        "${ROOT_DIR}/caddy" \
        "${ROOT_DIR}/dist/caddy-linux-${ARCH}" \
        "${ROOT_DIR}/bin/${ARCH}/caddy" \
        "${ROOT_DIR}/caddy-linux-${ARCH}"
    do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    die "没有找到 ${ARCH} 架构的 Caddy 二进制，请使用 --binary 指定。"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "缺少 sha256sum/shasum，无法生成校验值。"
    fi
}

main() {
    local binary_path payload_dir payload_tar installer_path installer_tmp manifest_file binary_sha256 built_at

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)
                ARCH="$(normalize_arch "${2:-}")" || die "不支持的架构: ${2:-}"
                shift 2
                ;;
            --binary)
                BINARY="${2:-}"
                shift 2
                ;;
            --output)
                OUTPUT="${2:-}"
                shift 2
                ;;
            --version)
                VERSION="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                if [[ -z "${ARCH}" ]]; then
                    ARCH="$(normalize_arch "$1")" || die "未知参数: $1"
                else
                    die "未知参数: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "${ARCH}" ]] || die "请通过 --arch 指定目标架构。"
    [[ -f "${INSTALLER_STUB}" ]] || die "缺少 install.sh"
    [[ -f "${README_FILE}" ]] || die "缺少 README.md"

    binary_path="$(resolve_binary)"
    installer_path="${OUTPUT:-${ROOT_DIR}/caddy-alidns-linux-${ARCH}.run}"

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    payload_dir="${WORK_DIR}/payload"
    mkdir -p "${payload_dir}"

    log "准备打包 ${ARCH} 离线安装包"
    log "Caddy 二进制: ${binary_path}"

    installer_tmp="${WORK_DIR}/install.sh"
    tr -d '\r' < "${INSTALLER_STUB}" > "${installer_tmp}"
    if [[ "$(tail -c 1 "${installer_tmp}" 2>/dev/null || true)" != "" ]]; then
        printf '\n' >> "${installer_tmp}"
    fi
    grep -q '^__PAYLOAD_BELOW__$' "${installer_tmp}" || die "install.sh 缺少 __PAYLOAD_BELOW__ 标记。"

    cp "${binary_path}" "${payload_dir}/caddy"
    chmod 0755 "${payload_dir}/caddy"
    cp "${README_FILE}" "${payload_dir}/README.md"

    binary_sha256="$(sha256_file "${payload_dir}/caddy")"
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    manifest_file="${payload_dir}/manifest.txt"
    cat > "${manifest_file}" <<EOF
arch=${ARCH}
built_at=${built_at}
binary_sha256=${binary_sha256}
version=${VERSION:-unknown}
source_binary=$(basename "${binary_path}")
EOF

    payload_tar="${WORK_DIR}/payload.tar.gz"
    tar -czf "${payload_tar}" -C "${payload_dir}" .

    cat "${installer_tmp}" "${payload_tar}" > "${installer_path}"
    chmod +x "${installer_path}"
    sha256_file "${installer_path}" > "${installer_path}.sha256"

    log "打包完成: ${installer_path}"
    log "安装包 SHA256: $(cat "${installer_path}.sha256")"
}

main "$@"
