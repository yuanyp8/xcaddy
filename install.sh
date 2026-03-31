#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="install"
CONFIG_FILE=""
FORCE=0
SKIP_ENABLE=0
ENABLE_METRICS=0
SITE_TEMPLATE="reverse-proxy"

AK=""
SK=""
TOKEN=""
REGION="cn-hangzhou"
EMAIL=""
ADMIN_ADDR="localhost:2019"
LISTEN=""
DOMAIN=""
BACKEND=""
WILDCARD=""
MAX_BODY=""
TEST_DOMAIN=""
CONNECT_HOST=""
CONNECT_PORT=""

INSTALL_BASE="/usr/local/lib/caddy"
RELEASES_DIR="${INSTALL_BASE}/releases"
TOOLS_DIR="${INSTALL_BASE}/tools"
README_TARGET="${INSTALL_BASE}/README.md"
MANIFEST_TARGET="${INSTALL_BASE}/manifest.txt"
BIN_LINK="/usr/local/bin/caddy"

CONF_DIR="/etc/caddy"
ENV_FILE="${CONF_DIR}/caddy.env"
MAIN_CADDYFILE="${CONF_DIR}/Caddyfile"
SITES_AVAIL_DIR="${CONF_DIR}/sites-available"
SITES_ENABLED_DIR="${CONF_DIR}/sites-enabled"
SNIPPETS_DIR="${CONF_DIR}/snippets"

DATA_DIR="/var/lib/caddy"
LOG_DIR="/var/log/caddy"
SERVICE_NAME="caddy"
SERVICE_USER="caddy"
SERVICE_GROUP="caddy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LIMIT_NOFILE="1048576"

PAYLOAD_ROOT=""
PAYLOAD_CADDY=""
PAYLOAD_README=""
PAYLOAD_MANIFEST=""
TMP_DIR=""

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}

usage() {
    cat <<'EOF'
用法:
  ./install.sh install [参数]
  ./install.sh precheck [参数]
  ./install.sh status
  ./install.sh test-runtime
  ./install.sh test-cert --domain image.example.com
  ./install.sh readme

常用参数:
  --config FILE         从配置文件读取参数，格式为 KEY=VALUE
  --domain DOMAIN       单域名入口，例如 image.example.com
  --listen ADDR         单域名入口，支持带端口，例如 image.example.com:9443
  --backend HOST:PORT   反向代理后端，例如 127.0.0.1:8080
  --wildcard ADDR       泛域名入口，例如 *.example.com 或 *.example.com:9443
  --site-template NAME  站点模板，支持 reverse-proxy / harbor
  --max-body VALUE      请求体上限，例如 200MB、2GB；传 0 表示不限制

证书参数:
  --ak VALUE            阿里云 AccessKey ID
  --sk VALUE            阿里云 AccessKey Secret
  --token VALUE         阿里云 SecurityToken，可选
  --region VALUE        AliDNS Region，默认 cn-hangzhou
  --email VALUE         ACME 注册邮箱，可选但推荐填写

运行参数:
  --enable-metrics      开启 Caddy Prometheus metrics
  --admin-addr ADDR     Caddy Admin API 地址，默认 localhost:2019
  --force               检测到用户已修改配置时强制覆盖，并自动备份旧文件
  --skip-enable         安装后不执行 systemctl enable/start

检测参数:
  --domain VALUE        test-cert 时的证书域名
  --connect-host HOST   test-cert 时显式指定连接主机，默认 localhost
  --connect-port PORT   test-cert 时显式指定连接端口，默认 443
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "请使用 root 或 sudo 执行。"
    fi
}

normalize_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf '%s\n' "${arch}" ;;
    esac
}

normalize_listen() {
    local value="${1:-}"
    value="${value#https://}"
    value="${value#http://}"
    value="${value%%/*}"
    if [[ -z "${value}" ]]; then
        die "监听地址不能为空。"
    fi
    if [[ "${value}" == *:* ]]; then
        printf '%s\n' "${value}"
    else
        printf '%s:443\n' "${value}"
    fi
}

host_part() {
    local value="${1:-}"
    if [[ "${value}" == *:* ]]; then
        printf '%s\n' "${value%:*}"
    else
        printf '%s\n' "${value}"
    fi
}

port_part() {
    local value="${1:-}"
    if [[ "${value}" == *:* ]]; then
        printf '%s\n' "${value##*:}"
    else
        printf '443\n'
    fi
}

safe_name() {
    printf '%s\n' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

load_config_file() {
    [[ -f "${CONFIG_FILE}" ]] || die "配置文件不存在: ${CONFIG_FILE}"
    log "读取配置文件: ${CONFIG_FILE}"
    set -a
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
    set +a
    AK="${AK:-${ALIYUN_ACCESS_KEY_ID:-${Ali_Key:-}}}"
    SK="${SK:-${ALIYUN_ACCESS_KEY_SECRET:-${Ali_Secret:-}}}"
    TOKEN="${TOKEN:-${ALIYUN_SECURITY_TOKEN:-${Ali_SecurityToken:-}}}"
    EMAIL="${EMAIL:-${ACME_EMAIL:-}}"
    REGION="${REGION:-${ALIYUN_REGION_ID:-cn-hangzhou}}"
    LISTEN="${LISTEN:-}"
    DOMAIN="${DOMAIN:-}"
    BACKEND="${BACKEND:-}"
    WILDCARD="${WILDCARD:-}"
    MAX_BODY="${MAX_BODY:-}"
    SITE_TEMPLATE="${SITE_TEMPLATE:-reverse-proxy}"
    ENABLE_METRICS="${ENABLE_METRICS:-0}"
    ADMIN_ADDR="${ADMIN_ADDR:-localhost:2019}"
}

resolve_payload() {
    local marker_line

    TMP_DIR="$(mktemp -d /tmp/caddy-installer.XXXXXX)"
    PAYLOAD_ROOT="${TMP_DIR}/payload"
    mkdir -p "${PAYLOAD_ROOT}"

    marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0" || true)"
    if [[ -n "${marker_line}" ]] && tail -n +"${marker_line}" "$0" | tar -xzf - -C "${PAYLOAD_ROOT}" >/dev/null 2>&1; then
        :
    elif [[ -f "${SCRIPT_DIR}/caddy" ]]; then
        cp "${SCRIPT_DIR}/caddy" "${PAYLOAD_ROOT}/caddy"
        [[ -f "${SCRIPT_DIR}/README.md" ]] && cp "${SCRIPT_DIR}/README.md" "${PAYLOAD_ROOT}/README.md"
        [[ -f "${SCRIPT_DIR}/manifest.txt" ]] && cp "${SCRIPT_DIR}/manifest.txt" "${PAYLOAD_ROOT}/manifest.txt"
    else
        die "没有找到离线 payload。请先通过 build.sh 打包，或将 caddy 二进制放在 install.sh 同目录。"
    fi

    PAYLOAD_CADDY="${PAYLOAD_ROOT}/caddy"
    PAYLOAD_README="${PAYLOAD_ROOT}/README.md"
    PAYLOAD_MANIFEST="${PAYLOAD_ROOT}/manifest.txt"

    [[ -f "${PAYLOAD_CADDY}" ]] || die "payload 中缺少 caddy 二进制。"
}

precheck_environment() {
    local cmd
    for cmd in awk sed tar systemctl install sha256sum ln grep; do
        command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令: ${cmd}"
    done

    "${PAYLOAD_CADDY}" version >/dev/null 2>&1 || die "当前 Caddy 二进制无法运行，请确认架构是否正确。"
    if ! "${PAYLOAD_CADDY}" list-modules 2>/dev/null | grep -qx 'dns.providers.alidns'; then
        die "当前 Caddy 二进制未包含 dns.providers.alidns 插件。"
    fi

    if [[ -n "${DOMAIN}" && -z "${LISTEN}" ]]; then
        LISTEN="${DOMAIN}"
    fi

    if [[ -n "${LISTEN}" && -n "${WILDCARD}" ]]; then
        die "--listen/--domain 和 --wildcard 只能二选一。"
    fi

    if [[ -n "${LISTEN}" ]]; then
        LISTEN="$(normalize_listen "${LISTEN}")"
        [[ -n "${BACKEND}" ]] || die "单域名反向代理模式必须提供 --backend。"
    fi

    if [[ -n "${WILDCARD}" ]]; then
        WILDCARD="$(normalize_listen "${WILDCARD}")"
    fi

    if [[ -n "${LISTEN}${WILDCARD}" ]]; then
        [[ -n "${AK}" ]] || die "已配置站点时必须提供 --ak。"
        [[ -n "${SK}" ]] || die "已配置站点时必须提供 --sk。"
    fi

    case "${ENABLE_METRICS}" in
        1|true|TRUE|yes|YES) ENABLE_METRICS=1 ;;
        *) ENABLE_METRICS=0 ;;
    esac

    case "${SITE_TEMPLATE}" in
        reverse-proxy|harbor) ;;
        *) die "不支持的站点模板: ${SITE_TEMPLATE}" ;;
    esac
}

install_binary() {
    local sha256 release_dir

    sha256="$(sha256sum "${PAYLOAD_CADDY}" | awk '{print $1}')"
    release_dir="${RELEASES_DIR}/${sha256}"
    install -d -m 0755 "${release_dir}"
    if [[ ! -f "${release_dir}/caddy" ]]; then
        install -m 0755 "${PAYLOAD_CADDY}" "${release_dir}/caddy"
    fi

    install -d -m 0755 "$(dirname "${BIN_LINK}")"
    ln -sfn "${release_dir}/caddy" "${BIN_LINK}"
}

ensure_user_group() {
    getent group "${SERVICE_GROUP}" >/dev/null 2>&1 || groupadd --system "${SERVICE_GROUP}"
    if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "${SERVICE_GROUP}" \
            --home-dir "${DATA_DIR}" \
            --shell /usr/sbin/nologin \
            "${SERVICE_USER}"
    fi
}

prepare_directories() {
    install -d -m 0755 "${INSTALL_BASE}" "${RELEASES_DIR}" "${TOOLS_DIR}"
    install -d -m 0755 "${CONF_DIR}" "${SITES_AVAIL_DIR}" "${SITES_ENABLED_DIR}" "${SNIPPETS_DIR}"
    install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${DATA_DIR}" "${LOG_DIR}"
}

safe_install_file() {
    local src="$1" dst="$2" mode="$3" owner_group="$4" backup_name

    install -d -m 0755 "$(dirname "${dst}")"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        return 0
    fi

    if [[ -f "${dst}" && "${FORCE}" -eq 0 ]]; then
        cp "${src}" "${dst}.dist"
        chmod "${mode}" "${dst}.dist"
        chown "${owner_group}" "${dst}.dist"
        warn "检测到 ${dst} 已被修改，已生成 ${dst}.dist，请人工比较后合并。"
        return 0
    fi

    if [[ -f "${dst}" && "${FORCE}" -eq 1 ]]; then
        backup_name="${dst}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${dst}" "${backup_name}"
        log "已备份 ${dst} -> ${backup_name}"
    fi

    install -m "${mode}" "${src}" "${dst}"
    chown "${owner_group}" "${dst}"
}

write_text_file() {
    local dst="$1" mode="$2" owner_group="$3" tmp_file="$4"
    safe_install_file "${tmp_file}" "${dst}" "${mode}" "${owner_group}"
}

write_env_file() {
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<EOF
# Caddy 运行环境变量
# 建议将本文件权限保持为 0600
ACME_EMAIL=${EMAIL}
CADDY_ADMIN_ADDR=${ADMIN_ADDR}
ALIYUN_ACCESS_KEY_ID=${AK}
ALIYUN_ACCESS_KEY_SECRET=${SK}
ALIYUN_REGION_ID=${REGION}
ALIYUN_SECURITY_TOKEN=${TOKEN}
ENABLE_METRICS=${ENABLE_METRICS}
EOF
    write_text_file "${ENV_FILE}" 0600 root:root "${tmp_file}"
    rm -f "${tmp_file}"
}

write_main_caddyfile() {
    local tmp_file
    tmp_file="$(mktemp)"

    {
        printf '{\n'
        printf '    admin {$CADDY_ADMIN_ADDR}\n'
        printf '    storage file_system {\n'
        printf '        root %s\n' "${DATA_DIR}"
        printf '    }\n'
        if [[ -n "${AK}" && -n "${SK}" ]]; then
            printf '    acme_dns alidns {\n'
            printf '        access_key_id {env.ALIYUN_ACCESS_KEY_ID}\n'
            printf '        access_key_secret {env.ALIYUN_ACCESS_KEY_SECRET}\n'
            printf '        region_id {env.ALIYUN_REGION_ID}\n'
            if [[ -n "${TOKEN}" ]]; then
                printf '        security_token {env.ALIYUN_SECURITY_TOKEN}\n'
            fi
            printf '    }\n'
        fi
        if [[ -n "${EMAIL}" ]]; then
            printf '    email {$ACME_EMAIL}\n'
        fi
        if [[ "${ENABLE_METRICS}" -eq 1 ]]; then
            printf '    metrics\n'
        fi
        printf '    log {\n'
        printf '        output stderr\n'
        printf '        format json\n'
        printf '        level INFO\n'
        printf '    }\n'
        printf '}\n\n'
        printf 'import %s/*.caddy\n' "${SITES_ENABLED_DIR}"
    } > "${tmp_file}"

    write_text_file "${MAIN_CADDYFILE}" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"
}

write_snippets() {
    local tmp_file

    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<'EOF'
header {
    -Server
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    X-XSS-Protection "1; mode=block"
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
}
EOF
    write_text_file "${SNIPPETS_DIR}/security-headers.caddy" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"

    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<'EOF'
header_up Host {host}
header_up X-Real-IP {remote_host}
header_up X-Forwarded-For {remote_host}
header_up X-Forwarded-Proto {scheme}
header_up X-Forwarded-Host {host}
EOF
    write_text_file "${SNIPPETS_DIR}/proxy-headers.caddy" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"
}

request_body_block() {
    if [[ -z "${MAX_BODY}" || "${MAX_BODY}" == "0" ]]; then
        return 0
    fi
    cat <<EOF
        request_body {
            max_size ${MAX_BODY}
        }
EOF
}

write_single_site() {
    local site_name site_file enabled_file redirect_file port tmp_file

    site_name="$(safe_name "${LISTEN}")"
    site_file="${SITES_AVAIL_DIR}/10-${site_name}.caddy"
    enabled_file="${SITES_ENABLED_DIR}/10-${site_name}.caddy"
    port="$(port_part "${LISTEN}")"
    tmp_file="$(mktemp)"

    cat > "${tmp_file}" <<EOF
${LISTEN} {
    encode zstd gzip
    import ${SNIPPETS_DIR}/security-headers.caddy

    route {
        @health path /healthz
        handle @health {
            respond "ok" 200
        }
$(request_body_block)
        handle {
            reverse_proxy ${BACKEND} {
                import ${SNIPPETS_DIR}/proxy-headers.caddy
                flush_interval -1
                transport http {
                    dial_timeout 10s
                    response_header_timeout 300s
                    read_timeout 0
                    write_timeout 0
                }
            }
        }
    }
}
EOF

    write_text_file "${site_file}" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"
    ln -sfn "${site_file}" "${enabled_file}"

    if [[ "${port}" != "443" ]]; then
        redirect_file="${SITES_AVAIL_DIR}/00-http-redirect-${site_name}.caddy"
        tmp_file="$(mktemp)"
        cat > "${tmp_file}" <<EOF
:80 {
    redir https://{host}:${port}{uri} permanent
}
EOF
        write_text_file "${redirect_file}" 0644 root:root "${tmp_file}"
        rm -f "${tmp_file}"
        ln -sfn "${redirect_file}" "${SITES_ENABLED_DIR}/00-http-redirect-${site_name}.caddy"
    fi

    if [[ "${SITE_TEMPLATE}" == "harbor" && -z "${MAX_BODY}" ]]; then
        warn "Harbor 模板通常建议配合 --max-body 0 使用，避免镜像推送被请求体限制。"
    fi

    log "已生成单域名站点: ${site_file}"
}

write_wildcard_site() {
    local site_name site_file enabled_file redirect_file port tmp_file

    site_name="$(safe_name "${WILDCARD}")"
    site_file="${SITES_AVAIL_DIR}/10-${site_name}.caddy"
    enabled_file="${SITES_ENABLED_DIR}/10-${site_name}.caddy"
    port="$(port_part "${WILDCARD}")"
    tmp_file="$(mktemp)"

    cat > "${tmp_file}" <<EOF
${WILDCARD} {
    encode zstd gzip
    import ${SNIPPETS_DIR}/security-headers.caddy

    @health path /healthz
    handle @health {
        respond "ok" 200
    }

    handle {
        header Content-Type application/json
        respond "{\"status\":\"ok\",\"gateway\":\"caddy\",\"host\":\"{host}\",\"message\":\"请为该子域名补充独立站点配置。\"}" 200
    }
}
EOF

    write_text_file "${site_file}" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"
    ln -sfn "${site_file}" "${enabled_file}"

    if [[ "${port}" != "443" ]]; then
        redirect_file="${SITES_AVAIL_DIR}/00-http-redirect-${site_name}.caddy"
        tmp_file="$(mktemp)"
        cat > "${tmp_file}" <<EOF
:80 {
    redir https://{host}:${port}{uri} permanent
}
EOF
        write_text_file "${redirect_file}" 0644 root:root "${tmp_file}"
        rm -f "${tmp_file}"
        ln -sfn "${redirect_file}" "${SITES_ENABLED_DIR}/00-http-redirect-${site_name}.caddy"
    fi

    log "已生成泛域名底座站点: ${site_file}"
}

write_service_file() {
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<EOF
[Unit]
Description=Caddy Web Server (AliDNS custom build)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN_LINK} run --environ --config ${MAIN_CADDYFILE}
ExecReload=${BIN_LINK} reload --config ${MAIN_CADDYFILE} --force
ExecStop=/bin/kill -s SIGTERM \$MAINPID
TimeoutStopSec=15s
LimitNOFILE=${LIMIT_NOFILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CONF_DIR} ${DATA_DIR} ${LOG_DIR}
WorkingDirectory=${DATA_DIR}
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
    write_text_file "${SERVICE_FILE}" 0644 root:root "${tmp_file}"
    rm -f "${tmp_file}"
}

write_runtime_test_tool() {
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[1/5] systemd 状态"
systemctl --no-pager --full status ${SERVICE_NAME} || true

echo
echo "[2/5] Caddy 版本"
${BIN_LINK} version

echo
echo "[3/5] AliDNS 模块检查"
${BIN_LINK} list-modules | grep -x 'dns.providers.alidns'

echo
echo "[4/5] 配置校验"
${BIN_LINK} validate --config ${MAIN_CADDYFILE} --adapter caddyfile

echo
echo "[5/5] 监听端口"
if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep -E ':80 |:443 |:2019 ' || true
fi
EOF
    write_text_file "${TOOLS_DIR}/test-caddy-runtime.sh" 0755 root:root "${tmp_file}"
    rm -f "${tmp_file}"
    ln -sfn "${TOOLS_DIR}/test-caddy-runtime.sh" /usr/local/bin/caddy-test-runtime
}

write_cert_test_tool() {
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
CONNECT_HOST="localhost"
CONNECT_PORT="443"

usage() {
    cat <<'USAGE'
用法:
  caddy-test-certificate --domain image.example.com [--connect-host localhost] [--connect-port 443]
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;
        --connect-host)
            CONNECT_HOST="${2:-}"
            shift 2
            ;;
        --connect-port)
            CONNECT_PORT="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] 未知参数: $1" >&2
            exit 1
            ;;
    esac
done

[[ -n "${DOMAIN}" ]] || { echo "[ERROR] --domain 不能为空" >&2; exit 1; }

echo "[INFO] openssl TLS 握手检查: ${CONNECT_HOST}:${CONNECT_PORT} (SNI=${DOMAIN})"
echo | openssl s_client -connect "${CONNECT_HOST}:${CONNECT_PORT}" -servername "${DOMAIN}" 2>/dev/null | \
    openssl x509 -noout -subject -issuer -dates -ext subjectAltName

echo
echo "[INFO] HTTP 头检查"
curl -kI --connect-timeout 10 "https://${CONNECT_HOST}:${CONNECT_PORT}/" -H "Host: ${DOMAIN}" || true

echo
echo "[INFO] 近 50 行 Caddy 证书相关日志"
journalctl -u caddy -n 50 --no-pager | grep -Ei 'acme|certificate|challenge|renew|obtain' || true
EOF
    write_text_file "${TOOLS_DIR}/test-caddy-certificate.sh" 0755 root:root "${tmp_file}"
    rm -f "${tmp_file}"
    ln -sfn "${TOOLS_DIR}/test-caddy-certificate.sh" /usr/local/bin/caddy-test-certificate
}

write_site_init_tool() {
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
BACKEND=""
MAX_BODY=""
SITE_TEMPLATE="reverse-proxy"
FORCE=0
ENABLE_LINK=1
DO_RELOAD=1

usage() {
    cat <<'USAGE'
用法:
  caddy-site-init --domain image.example.com --backend 127.0.0.1:8080 [选项]

参数:
  --domain DOMAIN           域名，可选带端口
  --backend HOST:PORT       反向代理后端
  --max-body VALUE          请求体限制，传 0 表示不限制
  --template NAME           reverse-proxy / harbor
  --force                   已存在时强制覆盖
  --disable-enable          只写 sites-available，不建立软链接
  --disable-reload          写完后不自动 reload
USAGE
}

while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --domain)
            DOMAIN="\${2:-}"
            shift 2
            ;;
        --backend)
            BACKEND="\${2:-}"
            shift 2
            ;;
        --max-body)
            MAX_BODY="\${2:-}"
            shift 2
            ;;
        --template)
            SITE_TEMPLATE="\${2:-}"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --disable-enable)
            ENABLE_LINK=0
            shift
            ;;
        --disable-reload)
            DO_RELOAD=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] 未知参数: \$1" >&2
            exit 1
            ;;
    esac
done

[[ -n "\${DOMAIN}" ]] || { echo "[ERROR] --domain 不能为空" >&2; exit 1; }
[[ -n "\${BACKEND}" ]] || { echo "[ERROR] --backend 不能为空" >&2; exit 1; }

if [[ "\${SITE_TEMPLATE}" == "harbor" && -z "\${MAX_BODY}" ]]; then
    MAX_BODY=0
fi

SAFE_NAME="\$(printf '%s' "\${DOMAIN}" | sed 's#[^A-Za-z0-9._-]#_#g')"
SITE_FILE="${SITES_AVAIL_DIR}/20-\${SAFE_NAME}.caddy"
LINK_FILE="${SITES_ENABLED_DIR}/20-\${SAFE_NAME}.caddy"
TMP_FILE="\$(mktemp)"

{
    printf '%s {\n' "\${DOMAIN}"
    printf '    encode zstd gzip\n'
    printf '    import %s/security-headers.caddy\n' "${SNIPPETS_DIR}"
    printf '\n'
    printf '    route {\n'
    printf '        @health path /healthz\n'
    printf '        handle @health {\n'
    printf '            respond "ok" 200\n'
    printf '        }\n'
    if [[ -n "\${MAX_BODY}" && "\${MAX_BODY}" != "0" ]]; then
        printf '        request_body {\n'
        printf '            max_size %s\n' "\${MAX_BODY}"
        printf '        }\n'
    fi
    printf '        handle {\n'
    printf '            reverse_proxy %s {\n' "\${BACKEND}"
    printf '                import %s/proxy-headers.caddy\n' "${SNIPPETS_DIR}"
    printf '                flush_interval -1\n'
    printf '                transport http {\n'
    printf '                    dial_timeout 10s\n'
    printf '                    response_header_timeout 300s\n'
    printf '                    read_timeout 0\n'
    printf '                    write_timeout 0\n'
    printf '                }\n'
    printf '            }\n'
    printf '        }\n'
    printf '    }\n'
    printf '}\n'
} > "\${TMP_FILE}"

if [[ -f "\${SITE_FILE}" && \${FORCE} -ne 1 ]]; then
    echo "[ERROR] 站点已存在: \${SITE_FILE}，如需覆盖请加 --force" >&2
    exit 1
fi

install -d -m 0755 "${SITES_AVAIL_DIR}" "${SITES_ENABLED_DIR}"
install -m 0644 "\${TMP_FILE}" "\${SITE_FILE}"
rm -f "\${TMP_FILE}"

if [[ \${ENABLE_LINK} -eq 1 ]]; then
    ln -sfn "\${SITE_FILE}" "\${LINK_FILE}"
fi

${BIN_LINK} validate --config ${MAIN_CADDYFILE} --adapter caddyfile
if [[ \${DO_RELOAD} -eq 1 ]] && systemctl is-active --quiet ${SERVICE_NAME}; then
    systemctl reload ${SERVICE_NAME}
fi

echo "[INFO] 站点文件已生成: \${SITE_FILE}"
EOF
    write_text_file "${TOOLS_DIR}/create-caddy-site.sh" 0755 root:root "${tmp_file}"
    rm -f "${tmp_file}"
    ln -sfn "${TOOLS_DIR}/create-caddy-site.sh" /usr/local/bin/caddy-site-init
}

install_readme_copy() {
    if [[ -f "${PAYLOAD_README}" ]]; then
        install -m 0644 "${PAYLOAD_README}" "${README_TARGET}"
    fi
}

install_manifest_copy() {
    if [[ -f "${PAYLOAD_MANIFEST}" ]]; then
        install -m 0644 "${PAYLOAD_MANIFEST}" "${MANIFEST_TARGET}"
    fi
}

validate_config() {
    "${BIN_LINK}" validate --config "${MAIN_CADDYFILE}" --adapter caddyfile
}

enable_and_start() {
    systemctl daemon-reload
    if [[ "${SKIP_ENABLE}" -eq 0 ]]; then
        systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            systemctl restart "${SERVICE_NAME}"
        else
            systemctl start "${SERVICE_NAME}"
        fi
    fi
}

install_action() {
    require_root
    resolve_payload
    precheck_environment

    ensure_user_group
    prepare_directories
    install_binary
    install_readme_copy
    install_manifest_copy
    write_env_file
    write_main_caddyfile
    write_snippets
    write_service_file
    write_runtime_test_tool
    write_cert_test_tool
    write_site_init_tool

    if [[ -n "${LISTEN}" ]]; then
        write_single_site
    fi
    if [[ -n "${WILDCARD}" ]]; then
        write_wildcard_site
    fi

    validate_config
    enable_and_start

    log "安装完成。"
    log "运行状态检查: caddy-test-runtime"
    if [[ -n "${LISTEN}" ]]; then
        log "证书检查: caddy-test-certificate --domain $(host_part "${LISTEN}") --connect-port $(port_part "${LISTEN}")"
    elif [[ -n "${WILDCARD}" ]]; then
        log "证书检查: caddy-test-certificate --domain $(host_part "${WILDCARD}" | sed 's#^\*\.#test.#') --connect-port $(port_part "${WILDCARD}")"
    fi
}

precheck_action() {
    resolve_payload
    precheck_environment
    log "预检查通过。"
    log "当前架构: $(normalize_arch)"
    log "Caddy 版本: $("${PAYLOAD_CADDY}" version)"
    log "AliDNS 模块存在: 是"
}

status_action() {
    if [[ ! -x "${BIN_LINK}" ]]; then
        die "当前系统尚未安装 Caddy。"
    fi
    if [[ -f "${MANIFEST_TARGET}" ]]; then
        echo "[INFO] 安装清单"
        cat "${MANIFEST_TARGET}"
        echo
    fi
    caddy-test-runtime
    echo
    echo "[INFO] 已启用站点列表"
    ls -l "${SITES_ENABLED_DIR}" 2>/dev/null || true
}

test_runtime_action() {
    if command -v caddy-test-runtime >/dev/null 2>&1; then
        caddy-test-runtime
    else
        die "未找到 caddy-test-runtime，请先执行 install。"
    fi
}

test_cert_action() {
    local domain port host

    domain="${TEST_DOMAIN:-${DOMAIN:-}}"
    if [[ -z "${domain}" && -n "${LISTEN}" ]]; then
        domain="$(host_part "${LISTEN}")"
    fi
    if [[ -z "${domain}" && -n "${WILDCARD}" ]]; then
        domain="$(host_part "${WILDCARD}" | sed 's#^\*\.#test.#')"
    fi
    [[ -n "${domain}" ]] || die "请通过 --domain 指定需要检测的证书域名。"

    host="${CONNECT_HOST:-localhost}"
    if [[ -n "${CONNECT_PORT}" ]]; then
        port="${CONNECT_PORT}"
    elif [[ -n "${LISTEN}" ]]; then
        port="$(port_part "${LISTEN}")"
    elif [[ -n "${WILDCARD}" ]]; then
        port="$(port_part "${WILDCARD}")"
    else
        port="443"
    fi

    if command -v caddy-test-certificate >/dev/null 2>&1; then
        caddy-test-certificate --domain "${domain}" --connect-host "${host}" --connect-port "${port}"
    else
        die "未找到 caddy-test-certificate，请先执行 install。"
    fi
}

readme_action() {
    if [[ -f "${PAYLOAD_README}" ]]; then
        cat "${PAYLOAD_README}"
    elif [[ -f "${SCRIPT_DIR}/README.md" ]]; then
        cat "${SCRIPT_DIR}/README.md"
    elif [[ -f "${README_TARGET}" ]]; then
        cat "${README_TARGET}"
    else
        usage
    fi
}

parse_args() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install|precheck|status|test-runtime|test-cert|readme)
                ACTION="$1"
                shift
                ;;
        esac
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="${2:-}"
                shift 2
                ;;
            --domain)
                DOMAIN="${2:-}"
                TEST_DOMAIN="${2:-}"
                shift 2
                ;;
            --listen)
                LISTEN="${2:-}"
                shift 2
                ;;
            --backend)
                BACKEND="${2:-}"
                shift 2
                ;;
            --wildcard)
                WILDCARD="${2:-}"
                shift 2
                ;;
            --site-template)
                SITE_TEMPLATE="${2:-}"
                shift 2
                ;;
            --max-body)
                MAX_BODY="${2:-}"
                shift 2
                ;;
            --ak|--access-key-id)
                AK="${2:-}"
                shift 2
                ;;
            --sk|--access-key-secret)
                SK="${2:-}"
                shift 2
                ;;
            --token|--security-token)
                TOKEN="${2:-}"
                shift 2
                ;;
            --region)
                REGION="${2:-}"
                shift 2
                ;;
            --email)
                EMAIL="${2:-}"
                shift 2
                ;;
            --admin-addr)
                ADMIN_ADDR="${2:-}"
                shift 2
                ;;
            --enable-metrics)
                ENABLE_METRICS=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --skip-enable)
                SKIP_ENABLE=1
                shift
                ;;
            --connect-host)
                CONNECT_HOST="${2:-}"
                shift 2
                ;;
            --connect-port)
                CONNECT_PORT="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done

    if [[ -n "${CONFIG_FILE}" ]]; then
        load_config_file
    fi
}

main() {
    trap cleanup EXIT
    parse_args "$@"

    case "${ACTION}" in
        install)
            install_action
            ;;
        precheck)
            precheck_action
            ;;
        status)
            status_action
            ;;
        test-runtime)
            test_runtime_action
            ;;
        test-cert)
            test_cert_action
            ;;
        readme)
            readme_action
            ;;
        *)
            die "不支持的动作: ${ACTION}"
            ;;
    esac
}

main "$@"
exit 0

__PAYLOAD_BELOW__
