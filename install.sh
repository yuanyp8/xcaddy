#!/bin/bash
# ==========================================================
# Caddy + AliDNS 生产级企业架构一键离线安装脚本
# 特性：仿 Nginx 目录结构、单域名/泛域名支持、路由分发模板、
#       HTTP强跳HTTPS中间件、Metrics 监控、标准代理头
# ==========================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}    $(date '+%F %T') $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $*" >&2; }
err()     { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
separator() { echo -e "\n${BLUE}================================================${NC}\n"; }

# ---------------------------------------------------------
# 核心路径定义 (类似 Nginx 的 /etc/nginx)
# ---------------------------------------------------------
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/caddy"
LOG_DIR="/var/log/caddy"
DATA_DIR="/var/lib/caddy"
SERVICE_NAME="caddy"
BIN_NAME="caddy"

# 企业架构子目录定义
SNIPPETS_DIR="${CONF_DIR}/snippets"         # 中间件层：可复用的配置片段
SITES_AVAIL_DIR="${CONF_DIR}/sites-available" # 业务层：各站点的完整配置
SITES_ENABLED_DIR="${CONF_DIR}/sites-enabled" # 业务层：软链接，控制哪些站点生效

# ⚠️ 注意：OFFLINE_BIN 移至 extract_payload 函数内部定义，避免 set -u 报错
WORKDIR=""

# 用户输入变量 - 单域名模式
AK=""
SK=""
REGION="cn-hangzhou"
LISTEN_ADDR=""  # 对外监听地址（前端入口），如 harbor.example.com:9443
BACKEND=""      # 后端真实地址，如 127.0.0.1:8080
MAX_BODY="5GB"  # 默认支持 5GB 超大请求体 (适合 Docker 镜像推送等场景)
CONFIG_FILE=""

# 用户输入变量 - 泛域名模式
WILDCARD_ADDR=""     # 泛域名监听地址，如 *.test.com:9443
DEPLOY_MODE="single" # 部署模式：single(单域名直连) 或 wildcard(泛域名底座)

# ---------------------------------------------------------
# 帮助信息 (纯中文详细解释)
# ---------------------------------------------------------
show_help() {
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} Caddy + 阿里云DNS 企业级一键部署脚本 (离线版)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BLUE}用法:${NC} sudo $0 [单域名模式参数] 或 [泛域名模式参数]"
    echo ""
    echo -e "${BLUE}描述:${NC}"
    echo "  本脚本将 Caddy 部署为企业级反向代理网关 (类似 Nginx)。"
    echo "  自动创建 snippets(中间件层) 和 sites-available(业务层) 目录。"
    echo "  默认允许 5GB 超大文件上传，完美适配 Harbor 等重型后端服务。"
    echo "  提供企业级 HTTP 强跳 HTTPS、路由分发等高级中间件模板。"
    echo ""
    echo -e "${BLUE}模式一：单域名直连模式 (适合单一业务快速上线)${NC}"
    echo "  --listen <地址:端口>    对外监听的域名和端口 (例如: harbor.example.com:9443)"
    echo "  --backend <地址:端口>   后端真实服务地址 (例如: 127.0.0.1:8080)"
    echo ""
    echo -e "${BLUE}模式二：泛域名底座模式 (适合多业务统一网关入口)${NC}"
    echo "  --wildcard <泛域名:端口> 泛域名监听地址 (例如: *.test.com:9443)"
    echo "  🌟 无需提供测试后端！脚本会利用 Caddy 原生能力自动返回 JSON 验证状态。"
    echo ""
    echo -e "${BLUE}全局必填参数 (两种模式均需)${NC}"
    echo "  --ak <字符串>         阿里云 AccessKey ID (用于自动申请 HTTPS 证书)"
    echo "  --sk <字符串>         阿里云 AccessKey Secret"
    echo ""
    echo -e "${BLUE}可选参数:${NC}"
    echo "  --max-body <大小>       允许的最大请求体大小 (默认: 5GB，支持 KB/MB/GB)"
    echo "  --region <字符串>     阿里云 Region ID (默认: cn-hangzhou)"
    echo "  --config <文件路径>   从指定的文件中读取以上所有参数 (推荐，避免密码泄露到命令历史)"
    echo "  -h, --help            显示本帮助信息"
    echo ""
    echo -e "${BLUE}配置文件格式示例:${NC}"
    echo "  # 单域名示例"
    echo "  AK=LTAI5txxxxxxxxxx"
    echo "  SK=xxxxxxxxxxxxxxxxx"
    echo "  LISTEN=harbor.example.com:9443"
    echo "  BACKEND=127.0.0.1:8080"
    echo ""
    echo "  # 泛域名示例"
    echo "  AK=LTAI5txxxxxxxxxx"
    echo "  SK=xxxxxxxxxxxxxxxxx"
    echo "  WILDCARD=*.test.com:9443"
    echo ""
    echo -e "${BLUE}部署后目录结构类似:${NC}"
    echo "  ${CONF_DIR}/"
    echo "  ├── Caddyfile               (主入口，仅包含全局配置和 import)"
    echo "  ├── snippets/               (中间件层：通用行为抽象)"
    echo "  │   ├── security-headers.conf (安全头)"
    echo "  │   ├── proxy-headers.conf    (代理透传头)"
    echo "  │   └── https-redirect.conf   (HTTP强跳HTTPS模板)"
    echo "  ├── sites-available/        (业务层：各个站点的完整配置)"
    echo "  │   └── example.conf"
    echo "  └── sites-enabled/          (软链接，控制站点启停)"
    echo "      └──  example.conf -> ../sites-available/ example.conf"
    exit 0
}

# ---------------------------------------------------------
# 加载配置文件
# ---------------------------------------------------------
load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo -e "${RED}错误：找不到配置文件 ${CONFIG_FILE}${NC}"
        exit 1
    fi
    echo -e "${GREEN}正在从 ${CONFIG_FILE} 加载配置...${NC}"
    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        if [[ -n "$key" && ! "$key" =~ ^# ]]; then
            case "$key" in
                AK) AK="$value" ;;
                SK) SK="$value" ;;
                LISTEN) LISTEN_ADDR="$value" ;;
                BACKEND) BACKEND="$value" ;;
                WILDCARD) WILDCARD_ADDR="$value" ;;
                MAX_BODY) MAX_BODY="$value" ;;
                REGION) REGION="$value" ;;
            esac
        fi
    done < "${CONFIG_FILE}"
}

# ---------------------------------------------------------
# 参数解析
# ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --ak) AK="$2"; shift 2 ;;
        --sk) SK="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --listen) LISTEN_ADDR="$2"; shift 2 ;;
        --backend) BACKEND="$2"; shift 2 ;;
        --wildcard) WILDCARD_ADDR="$2"; shift 2 ;;
        --max-body) MAX_BODY="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) err "未知参数: $1 (使用 -h 查看帮助)" ;;
    esac
done

[ -n "${CONFIG_FILE}" ] && load_config

# ---------------------------------------------------------
# 交互式向导
# ---------------------------------------------------------
if [ -z "${LISTEN_ADDR}" ] && [ -z "${WILDCARD_ADDR}" ] || [ -z "${AK}" ]; then
    separator
    echo -e "${BLUE}  Caddy + AliDNS 企业级反向代理网关部署向导${NC}"
    separator
    
    echo -e "${YELLOW}请选择部署模式:${NC}"
    echo "  1) 单域名直连模式 (一个域名直接代理到一个后端)"
    echo "  2) 泛域名底座模式 (申请泛域名证书，后续按需配置子域名/路径路由)"
    read -p "请输入选项 [1/2] (默认 1): " MODE_OPTION
    MODE_OPTION=${MODE_OPTION:-"1"}

    if [ "$MODE_OPTION" == "2" ]; then
        DEPLOY_MODE="wildcard"
        echo -e "${CYAN}--- 已选择：泛域名底座模式 ---${NC}"
        read -p "请输入泛域名监听地址 [如 *.test.com:9443]: " WILDCARD_ADDR
        [ -z "$WILDCARD_ADDR" ] && { err "泛域名不能为空"; }
        echo -e "${GREEN}提示：底座将利用 Caddy 原生能力自动返回测试 JSON，无需额外后端。${NC}"
    else
        DEPLOY_MODE="single"
        echo -e "${CYAN}--- 已选择：单域名直连模式 ---${NC}"
        read -p "请输入对外监听地址 [域名:端口] (例如 harbor.test.com:9443): " LISTEN_ADDR
        [ -z "$LISTEN_ADDR" ] && { err "监听地址不能为空"; }
        read -p "请输入后端真实服务地址 [IP:端口] (例如 127.0.0.1:8080): " BACKEND
        [ -z "$BACKEND" ] && { err "后端地址不能为空"; }
    fi
    
    read -p "请输入最大上传大小 (直接回车默认 5GB，适合 Harbor 推镜像): " INPUT_MAX_BODY
    MAX_BODY=${INPUT_MAX_BODY:-"5GB"}
    
    echo -e "${YELLOW}[阿里云 API 凭证配置]${NC}"
    read -p "请输入 AccessKey ID: " AK
    [ -z "$AK" ] && { err "AK不能为空"; }
    
    read -sp "请输入 AccessKey Secret (输入不显示): " SK
    echo ""
    [ -z "$SK" ] && { err "SK不能为空"; }
    
    read -p "请输入 Region ID (默认 cn-hangzhou 直接回车): " INPUT_REGION
    REGION=${INPUT_REGION:-cn-hangzhou}
fi

# 自动推断模式
if [ -n "${WILDCARD_ADDR}" ]; then
    DEPLOY_MODE="wildcard"
elif [ -n "${LISTEN_ADDR}" ]; then
    DEPLOY_MODE="single"
fi

# ---------------------------------------------------------
# 核心提取逻辑 (Nacos 架构核心)
# ---------------------------------------------------------
extract_payload() {
    # 初始化 WORKDIR 并在此处定义 OFFLINE_BIN，彻底避免 set -u 报错
    WORKDIR="/tmp/caddy-installer-$$"
    local OFFLINE_BIN="${WORKDIR}/${BIN_NAME}"

    log "正在解压离线文件..."
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    local payload_line
    payload_line=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0") || true
    [[ -n "$payload_line" ]] || err "离线安装包已损坏：找不到数据分割符"

    tail -n +"$payload_line" "$0" | tar -xz -C "$WORKDIR"

    [[ -f "$OFFLINE_BIN" ]] || err "离线安装包已损坏：找不到 caddy 二进制"
}


# ---------------------------------------------------------
# 数据清洗与预检查
# ---------------------------------------------------------
pre_check() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：必须使用 root 权限运行 (使用 sudo ./xxx.run)${NC}"
        exit 1
    fi

    # 清洗单域名
    if [ "$DEPLOY_MODE" == "single" ]; then
        LISTEN_ADDR=$(echo "${LISTEN_ADDR}" | sed 's|^https\?://||' | sed 's|/.*||')
        LISTEN_PORT=$(echo "$LISTEN_ADDR" | grep -oE '[0-9]+$' || true)
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT="443"
    fi

    # 清洗泛域名
    if [ "$DEPLOY_MODE" == "wildcard" ]; then
        WILDCARD_ADDR=$(echo "${WILDCARD_ADDR}" | sed 's|^https\?://||' | sed 's|/.*||')
        WILDCARD_PORT=$(echo "$WILDCARD_ADDR" | grep -oE '[0-9]+$' || true)
        [[ -z "$WILDCARD_PORT" ]] && WILDCARD_PORT="443"
    fi
}

# ==========================================================
# 核心安装逻辑
# ==========================================================
do_install() {
    log "[1/6] 停止旧服务并备份配置..."
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    if [ -d "${CONF_DIR}" ]; then
        BACKUP_DIR="${CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}检测到旧配置，正在备份至 ${BACKUP_DIR} ...${NC}"
        mv "${CONF_DIR}" "${BACKUP_DIR}"
    fi

    log "[2/6] 初始化系统与企业级目录环境..."
    id -u ${SERVICE_NAME} &>/dev/null || useradd -r -s /sbin/nologin ${SERVICE_NAME}
    mkdir -p "${CONF_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${SNIPPETS_DIR}" "${SITES_AVAIL_DIR}" "${SITES_ENABLED_DIR}"
    chown -R ${SERVICE_NAME}:${SERVICE_NAME} "${LOG_DIR}" "${DATA_DIR}"

    log "[3/6] 部署二进制与系统服务..."
    cp -f "${WORKDIR}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    chmod 755 "${INSTALL_DIR}/${BIN_NAME}"

    # 🚀 核心改变：不再手动写 service 文件，不再 setcap，全交给 Caddy 官方处理
    # caddy service install 会自动创建最安全的 systemd 服务并处理端口权限
    ${INSTALL_DIR}/${BIN_NAME} service install

    log "[4/6] 构建企业级中间件层..."

    # 1. 生成 snippets/security-headers.conf (安全头中间件)
    cat > "${SNIPPETS_DIR}/security-headers.conf" << 'EOF'
# ==========================================
# 中间件层：安全响应头
# ==========================================
header {
    # 防止点击劫持
    X-Frame-Options "SAMEORIGIN"
    # 防止 MIME 类型嗅探
    X-Content-Type-Options "nosniff"
    # XSS 防护 (旧版浏览器兼容)
    X-XSS-Protection "1; mode=block"
    # 严格传输安全 (HSTS)，强制 1 年使用 HTTPS
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    # 控制 Referrer 信息泄露
    Referrer-Policy "strict-origin-when-cross-origin"
}
EOF

    # 2. 生成 snippets/proxy-headers.conf (标准代理透传中间件)
    cat > "${SNIPPETS_DIR}/proxy-headers.conf" << 'EOF'
# ==========================================
# 中间件层：反向代理标准透传头
# 确保后端业务能拿到真实的客户端 IP 和协议
# ==========================================
header_up X-Real-IP {remote_host}
header_up X-Forwarded-For {remote_host}
header_up X-Forwarded-Proto {scheme}
header_up X-Forwarded-Host {host}
header_up X-Forwarded-Port {server_port}

# 清除后端可能返回的不安全头
header_down -X-Powered-By
header_down -Server
EOF

    # 3. 生成 snippets/https-redirect.conf (HTTP 强跳 HTTPS 中间件模板)
    cat > "${SNIPPETS_DIR}/https-redirect.conf" << 'EOF'
# ==========================================
# 中间件模板：HTTP 强制跳转 HTTPS
# ==========================================
# ⚠️ 注意：如果您的监听端口是标准的 443，Caddy 会自动在 80 端口处理跳转，无需引入此文件！
# 仅当您使用了非标准端口（例如 9443），且希望用户访问 80 端口时能跳转到 9443 时，才需要引入。
#
# 使用方法：
# 1. 新建一个站点文件，例如：vi /etc/caddy/sites-available/http-redirect.conf
# 2. 写入以下内容：
#    :80 {
#        import snippets/https-redirect.conf
#    }
# 3. 软链接并重载：ln -s ... && systemctl reload caddy
# ==========================================

redir https://{host}:9443{uri} permanent
EOF

    log "[5/6] 构建业务层配置..."

    if [ "$DEPLOY_MODE" == "single" ]; then
        build_single_site
    else
        build_wildcard_site
    fi

    # 生成主入口 Caddyfile (仅负责全局和引入)
    cat > "${CONF_DIR}/Caddyfile" << EOF
# ==========================================
# Caddy 主配置文件 (全局设置层)
# 类比 Nginx 的 nginx.conf
# ==========================================
{
    # 阿里云 DNS 插件全局凭证 (申请证书用)
    dns alidns {
        access_key_id     ${AK}
        access_key_secret ${SK}
        region_id         ${REGION}
    }

    # 全局日志格式 (输出标准 JSON，方便 ELK/Jaeger 采集)
    log {
        format json {
            level INFO
        }
    }

    # 全局超大请求体支持 (默认 5GB，专为 Docker/Harbor 镜像推送等场景设计)
    # 如果不设置，Caddy 默认不会限制，但显式声明可避免某些极端情况
    servers {
        max_body_size ${MAX_BODY}
    }

    # 开启 Prometheus Metrics 监控能力
    # 注意：默认监听在 Caddy 管理端口 (localhost:2019)
    # 可通过 curl localhost:2019/metrics 获取指标
    servers {
        metrics
    }
    
    # 禁用默认的 Admin API 页面公网访问 (安全加固)
    admin off
}

# ==========================================
# 引入业务层 (自动加载所有已启用的站点)
# 类比 Nginx 的 include /etc/nginx/sites-enabled/*;
# ==========================================
import sites-enabled/*
EOF

    # 锁定配置文件权限 (AK/SK 在里面)
    chown -R root:root "${CONF_DIR}"
    chmod 600 "${CONF_DIR}/Caddyfile"
    chmod 644 "${SNIPPETS_DIR}"/*.conf "${SITES_AVAIL_DIR}"/*.conf

    echo -e "${GREEN}[6/6] 启动服务并设置开机自启...${NC}"
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    systemctl restart ${SERVICE_NAME}
}

# ---------------------------------------------------------
# 子逻辑：构建单域名直连站点
# ---------------------------------------------------------
build_single_site() {
    log "  -> 正在生成单域名直连配置..."
    SAFE_FILENAME=$(echo "${LISTEN_ADDR}" | sed 's/[:.]/_/g')
    SITE_CONF="${SITES_AVAIL_DIR}/${SAFE_FILENAME}.conf"

    cat > "${SITE_CONF}" << EOF
# ==========================================
# 业务层：${LISTEN_ADDR} (反向代理网关)
# ==========================================
 ${LISTEN_ADDR} {
    tls {
        dns alidns {
            propagation_timeout 5m
            resolvers 223.5.5.5
        }
    }

    # 引入全局安全头中间件
    import snippets/security-headers.conf
    # 引入代理透传头中间件
    import snippets/proxy-headers.conf

    # 纯反向代理到后端
    reverse_proxy ${BACKEND} {
        # 传输优化：支持 WebSocket 升级及大文件流式传输 (永不超时断连)
        transport http {
            read_timeout 0
            write_timeout 0
            dial_timeout 5s
        }
    }
}
EOF

    ln -sf "${SITES_AVAIL_DIR}/${SAFE_FILENAME}.conf" "${SITES_ENABLED_DIR}/${SAFE_FILENAME}.conf"
}

# ---------------------------------------------------------
# 子逻辑：构建泛域名底座及高级路由模板
# ---------------------------------------------------------
build_wildcard_site() {
    log "  -> 正在生成泛域名底座配置..."
    WC_SAFE_FILENAME=$(echo "${WILDCARD_ADDR}" | sed 's/[:.]/_/g')
    WC_CONF="${SITES_AVAIL_DIR}/00-${WC_SAFE_FILENAME}.conf"

    # 1. 生成实际生效的泛域名兜底配置 (利用 Caddy 原生 respond，无需后端)
    cat > "${WC_CONF}" << EOF
# ==========================================
# 业务层：${WILDCARD_ADDR} (泛域名底座)
# 说明：此配置用于首次申请泛域名证书。
#       所有未匹配具体子域名的流量，将由 Caddy 直接返回 JSON 提示，无需额外后端。
# ==========================================
 ${WILDCARD_ADDR} {
    tls {
        dns alidns {
            propagation_timeout 5m
            resolvers 223.5.5.5
        }
    }

    # 兜底响应：直接由 Caddy 吐出 JSON，证明网关与证书均生效
    respond "{
  \"status\": \"ok\",
  \"message\": \"Caddy Wildcard Gateway Base is Running.\",
  \"hit_host\": \"{host}\",
  \"note\": \"Please configure specific subdomain routing in sites-available directory.\"
}" 200
}
EOF
    ln -sf "${WC_CONF}" "${SITES_ENABLED_DIR}/00-${WC_SAFE_FILENAME}.conf"

    # 2. 生成详细的业务路由配置模板 (不启用，供用户参考)
    ROUTE_TEMPLATE="${SITES_AVAIL_DIR}/01-custom-routes-template.conf"
    cat > "${ROUTE_TEMPLATE}" << 'EOF'
# ==========================================================
# 🚨 企业级业务路由分发配置模板 (仅供参考，默认未启用) 🚨
# ==========================================================
# 当您成功申请泛域名证书后，可以通过创建新的配置文件来精细化控制流量。
# Caddy 的匹配原则：长域名优先于短域名，长路径优先于短路径。
# ==========================================================


# ----------------------------------------------------------
# 场景 1：基于子域名的流量分发 (最常用)
# ----------------------------------------------------------
# 原理：访问 svca.test.com:9443 走后端A，访问 svcb.test.com:9443 走后端B
# 注意：无需重复写 tls 和 dns alidns 块，因为上面的 *.test.com 已经申请了泛域名证书！
# ----------------------------------------------------------

# svca.test.com:9443 {
#     import snippets/security-headers.conf
#     import snippets/proxy-headers.conf
#     
#     reverse_proxy 127.0.0.1:8080 {
#         transport http {
#             read_timeout 0
#             write_timeout 0
#         }
#     }
# }
#
# svcb.test.com:9443 {
#     import snippets/security-headers.conf
#     import snippets/proxy-headers.conf
#     
#     reverse_proxy 127.0.0.1:8081 {
#         transport http {
#             read_timeout 0
#             write_timeout 0
#         }
#     }
# }


# ----------------------------------------------------------
# 场景 2：基于 URL 路径的流量分发 (单域名多微服务)
# ----------------------------------------------------------
# 原理：同一个域名下，根据访问的路径前缀，转给不同的后端。
# ⚠️ 注意：必须使用 handle 指令，且长路径必须写在短路径的上面！
# ----------------------------------------------------------

# app.test.com:9443 {
#     import snippets/security-headers.conf
#     import snippets/proxy-headers.conf
# 
#     # 匹配 /a/ 开头的请求，转发给 8080
#     handle /a/* {
#         reverse_proxy 127.0.0.1:8080
#     }
#     
#     # 匹配 /b/ 开头的请求，转发给 8081
#     handle /b/* {
#         reverse_proxy 127.0.0.1:8081
#     }
#     
#     # 兜底策略：其他所有请求返回 404 (按需开启)
#     # handle {
#     #     respond "Not Found" 404
#     # }
# }


# ----------------------------------------------------------
# 场景 3：如果您的端口不是 443，如何配置 HTTP(80) 强跳转 HTTPS(9443)?
# ----------------------------------------------------------
# 如果监听的是 9443，用户直接敲 IP 或域名(默认80端口)是不会自动跳转的。
# 取消下方注释，可以让访问 80 端口的流量强制跳到 9443。
# ----------------------------------------------------------

# :80 {
#     import snippets/https-redirect.conf
# }

EOF
    warn "  -> 已生成详细的路由分发模板文件：${ROUTE_TEMPLATE}"
    warn "  -> 该模板默认未启用。如需配置子域名/路径分流，请参照模板修改，然后软链接到 sites-enabled 并 reload。"
}

# ---------------------------------------------------------
# 证书与服务状态验证
# ---------------------------------------------------------
verify() {
    echo ""
    log "正在验证服务与证书状态 (首次申请需 10-30 秒)..."

    sleep 3
    if ! systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${RED}❌ Caddy 服务启动失败！${NC}"
        echo -e "${RED}请检查配置语法：${INSTALL_DIR}/${BIN_NAME} validate --config ${CONF_DIR}/Caddyfile${NC}"
        echo -e "${RED}或查看详细日志：journalctl -u caddy -n 30 --no-pager${NC}"
        exit 1
    fi

    # 确定验证的端口和 SNI 域名
    local VERIFY_PORT=""
    local VERIFY_SNI=""
    if [ "$DEPLOY_MODE" == "single" ]; then
        VERIFY_PORT="$LISTEN_PORT"
        VERIFY_SNI="${LISTEN_ADDR%%:*}"
    else
        VERIFY_PORT="$WILDCARD_PORT"
        # 泛域名证书无法直接用 * 做 SNI 握手，取一个测试用的前缀
        VERIFY_SNI="test.${WILDCARD_ADDR%%:*}"
        VERIFY_SNI="${VERIFY_SNI#*.}" # 去掉开头的 test.
    fi

    CHECK_RESULT=0
    for i in {1..8}; do
        sleep 5
        # 动态使用监听端口进行 SSL 握手验证
        CERT_ISSUER=$(echo | openssl s_client -connect localhost:${VERIFY_PORT} -servername "${VERIFY_SNI}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
                
        if echo "$CERT_ISSUER" | grep -qi "Let's Encrypt\|R3\|E1"; then
            echo -e "${GREEN}✅ 恭喜！SSL 证书申请成功且已生效！${NC}"
            CHECK_RESULT=1
            break
        fi
    done

    if [ $CHECK_RESULT -eq 0 ]; then
        echo -e "${YELLOW}⚠️ 证书可能仍在申请中或申请失败。${NC}"
        echo -e "${YELLOW}常见原因：1. 域名未解析到本机IP  2. 阿里云AK/SK权限不足  3. 防火墙未放行端口${NC}"
        echo -e "${YELLOW}你可以稍后手动检查：journalctl -u caddy -f${NC}"
    fi
}

# ---------------------------------------------------------
# 完成 & 架构说明输出
# ---------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}                  🚀 部署完成总结${NC}"
    echo -e "${CYAN}============================================================${NC}"

    if [ "$DEPLOY_MODE" == "single" ]; then
        echo -e "运行模式:   ${GREEN}单域名直连模式${NC}"
        echo -e "对外入口:   ${GREEN}https://${LISTEN_ADDR}${NC}"
        echo -e "后端代理:   ${GREEN}${BACKEND}${NC}"
    else
        echo -e "运行模式:   ${GREEN}泛域名底座模式${NC}"
        echo -e "管辖域名:   ${GREEN}https://${WILDCARD_ADDR}${NC}"
        echo -e "兜底策略:   ${GREEN}Caddy 原生响应 (无需后端，直接返回 JSON 状态码)${NC}"
        echo -e "${YELLOW}👉 下一步操作提示:${NC}"
        echo -e "当前所有未配置的子域名访问将返回 JSON 提示。如需配置业务路由(如 svca/svcb 或 /a /b 分发)："
        echo -e "  ${CYAN}vim ${SITES_AVAIL_DIR}/01-custom-routes-template.conf${NC}"
        echo -e "编辑完成后，将其软链接至 ${SITES_ENABLED_DIR} 并执行 systemctl reload caddy"
    fi

    echo -e "上传限制:   ${GREEN}${MAX_BODY}${NC} (完美支持大文件上传/镜像推送)"

    echo ""
    echo -e "${BLUE}📊 监控指标:${NC}"
    echo -e "已内置 Prometheus 指标采集。在服务器本机执行以下命令获取："
    echo -e "  ${YELLOW}curl http://localhost:2019/metrics${NC}"

    echo ""
    echo -e "${BLUE}📁 企业级目录架构说明:${NC}"
    echo -e "主配置:     ${CONF_DIR}/Caddyfile (仅管全局和 import)"
    echo -e "中间件层:   ${CONF_DIR}/snippets/ (存放安全头、代理头、HTTP强跳等通用片段)"
    echo -e "业务层:     ${CONF_DIR}/sites-available/ (存放具体域名的完整配置)"
    echo -e "启停控制:   ${CONF_DIR}/sites-enabled/ (软链接，删除链接即下线域名，类似 Nginx)"

    echo ""
    echo -e "${BLUE}🛠️  日常运维命令:${NC}"
    echo -e "重载配置:   ${YELLOW}systemctl reload caddy${NC}"
    echo -e "新增站点:   1. 在 ${SITES_AVAIL_DIR} 写新域名conf"
    echo -e "            2. 执行: ln -s ${SITES_AVAIL_DIR}/new.conf ${SITES_ENABLED_DIR}/"
    echo -e "            3. 执行: systemctl reload caddy"
    echo -e "下线站点:   ${YELLOW}rm ${SITES_ENABLED_DIR}/example.conf && systemctl reload caddy${NC}"
    echo -e "查看实时日志: ${YELLOW}journalctl -u caddy -f${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
main() {
    trap 'rm -rf "$WORKDIR"' EXIT

    separator
    echo -e "${GREEN}Caddy + AliDNS Enterprise Installer${NC}"
    separator

    extract_payload
    pre_check
    do_install
    verify
    print_summary
}

main "$@"
exit 0

__PAYLOAD_BELOW__