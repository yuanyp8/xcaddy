#!/bin/bash
# ==========================================================
# Caddy + AliDNS 生产级企业架构一键离线安装脚本
# 特性：仿 Nginx 目录结构、前后端分离、Metrics 监控、标准代理头
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

# 解压后的资源路径
OFFLINE_BIN="${WORKDIR}/${BIN_NAME}"
SERVICE_FILE="${WORKDIR}/caddy.service"

# 用户输入变量
AK=""
SK=""
REGION="cn-hangzhou"
LISTEN_ADDR=""  # 对外监听地址（前端入口），如 harbor.example.com:9443
BACKEND=""      # 后端真实地址，如 127.0.0.1:8080
MAX_BODY="5GB"  # 默认支持 5GB 超大请求体 (适合 Docker 镜像推送等场景)
CONFIG_FILE=""

# ---------------------------------------------------------
# 帮助信息 (纯中文详细解释)
# ---------------------------------------------------------
show_help() {
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} Caddy + 阿里云DNS 企业级一键部署脚本 (离线版)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BLUE}用法:${NC} sudo $0 [选项参数]"
    echo ""
    echo -e "${BLUE}描述:${NC}"
    echo "  本脚本将 Caddy 部署为企业级反向代理网关 (类似 Nginx)。"
    echo "  自动创建 snippets(中间件层) 和 sites-available(业务层) 目录。"
    echo "  默认允许 5GB 超大文件上传，完美适配 Harbor 等重型后端服务。"
    echo ""
    echo -e "${BLUE}必填参数 (可通过配置文件或命令行传入,为空则进入引导化配置):${NC}"
    echo "  --ak <字符串>         阿里云 AccessKey ID (用于自动申请 HTTPS 证书)"
    echo "  --sk <字符串>         阿里云 AccessKey Secret"
    echo "  --listen <地址:端口>    对外监听的域名和端口 (例如: harbor.example.com:9443)"
    echo "  --backend <地址:端口>   后端真实服务地址 (例如: 127.0.0.1:8080)"
    echo ""
    echo -e "${BLUE}可选参数:${NC}"
    echo "  --max-body <大小>       允许的最大请求体大小 (默认: 5GB，支持 KB/MB/GB)"
    echo "  --region <字符串>     阿里云 Region ID (默认: cn-hangzhou)"
    echo "  --config <文件路径>   从指定的文件中读取以上所有参数 (推荐，避免密码泄露到命令历史)"
    echo "  -h, --help            显示本帮助信息"
    echo ""
    echo -e "${BLUE}配置文件格式示例:${NC}"
    echo "  AK=LTAI5txxxxxxxxxx"
    echo "  SK=xxxxxxxxxxxxxxxxx"
    echo "  LISTEN=harbor.example.com:9443"
    echo "  BACKEND=127.0.0.1:8080"
    echo "  MAX_BODY=10GB"
    echo ""
    echo -e "${BLUE}部署后目录结构类似:${NC}"
    echo "  ${CONF_DIR}/"
    echo "  ├── Caddyfile               (主入口，仅包含全局配置和 import)"
    echo "  ├── snippets/               (中间件层：通用行为抽象)"
    echo "  │   ├── security-headers.conf"
    echo "  │   └── proxy-headers.conf"
    echo "  ├── sites-available/        (业务层：各个站点的完整配置)"
    echo "  │   └── ${DOMAIN}.conf"
    echo "  └── sites-enabled/          (软链接，控制站点启停)"
    echo "      └── ${DOMAIN}.conf -> ../sites-available/${DOMAIN}.conf"
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
        --max-body) MAX_BODY="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) err "未知参数: $1 (使用 -h 查看帮助)" ;;
    esac
done

[ -n "${CONFIG_FILE}" ] && load_config

# ---------------------------------------------------------
# 交互式向导
# ---------------------------------------------------------
if [ -z "${LISTEN_ADDR}" ] || [ -z "${AK}" ]; then
    separator
    echo -e "${BLUE}  Caddy + AliDNS 反向代理网关部署向导${NC}"
    separator
    
    read -p "请输入对外监听地址 [域名:端口] (例如 harbor.test.com:9443): " LISTEN_ADDR
    [ -z "$LISTEN_ADDR" ] && { err "监听地址不能为空"; }
    
    read -p "请输入后端真实服务地址 [IP:端口] (例如 127.0.0.1:8080): " BACKEND
    [ -z "$BACKEND" ] && { err "后端地址不能为空"; }
    
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

# ---------------------------------------------------------
# 核心提取逻辑 (Nacos 架构核心)
# ---------------------------------------------------------
extract_payload() {
    log "正在解压离线文件..."
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    local payload_line
    payload_line=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0") || true
    [[ -n "$payload_line" ]] || err "离线安装包已损坏：找不到数据分割符"

    tail -n +"$payload_line" "$0" | tar -xz -C "$WORKDIR"

    [[ -f "$OFFLINE_BIN" ]] || err "离线安装包已损坏：找不到 caddy 二进制"
    [[ -f "$SERVICE_FILE" ]] || err "离线安装包已损坏：找不到 caddy.service"
}


# ---------------------------------------------------------
# 数据清洗与预检查
# ---------------------------------------------------------
pre_check() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：必须使用 root 权限运行 (使用 sudo ./xxx.run)${NC}"
        exit 1
    fi

    if [ ! -f "${OFFLINE_BIN}" ]; then
        echo -e "${RED}错误：离线安装包损坏，找不到二进制文件${NC}"
        exit 1
    fi

    # 去除可能的协议前缀，提取纯净的 地址:端口
    LISTEN_ADDR=$(echo "${LISTEN_ADDR}" | sed 's|^https\?://||' | sed 's|/.*||')
    
    # 提取端口 (用于后续证书验证)
    LISTEN_PORT=$(echo "$LISTEN_ADDR" | grep -oE '[0-9]+$' || true)
    [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT="443"
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
    cp -f "${OFFLINE_BIN}" "${INSTALL_DIR}/${BIN_NAME}"
    chmod 755 "${INSTALL_DIR}/${BIN_NAME}"
    setcap cap_net_bind_service=+ep "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null || true
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv "${INSTALL_DIR}/${BIN_NAME}" >/dev/null 2>&1 || true
    fi
    cp -f "${SERVICE_FILE}" /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload

    log "[4/6] 构建中间件层 与业务层..."


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

# 3. 生成具体的业务站点配置 (业务层)
    SITE_CONF="${SITES_AVAIL_DIR}/${DOMAIN}.conf"

    if [ -n "${FRONTEND}" ]; then
        # --- 前后端分离模式 ---
        chown -R ${SERVICE_NAME}:${SERVICE_NAME} "${FRONTEND}"
    
        cat > "${SITE_CONF}" << EOF
# ==========================================
# 业务层：${DOMAIN} (前后端分离模式)
# ==========================================
 ${DOMAIN} {
    tls {
        dns alidns {
            propagation_timeout 5m
            resolvers 223.5.5.5
        }
    }

    # 引入全局安全头中间件
    import snippets/security-headers.conf

    # 托管前端静态文件 (Vue/React 等)
    root * ${FRONTEND}
    try_files {path} /index.html
    file_server {
        precompressed br gzip
    }

    # 将后端 API 代理挂载到 /api 路径下
    handle /api/* {
        # 引入代理透传头中间件
        import snippets/proxy-headers.conf
        
        reverse_proxy ${BACKEND} {
            # 健康检查与故障转移
            health_uri /health
            health_interval 10s
            health_timeout 5s
            
            # 传输优化：支持 WebSocket 升级及大文件流式传输
            transport http {
                read_timeout 0
                write_timeout 0
                dial_timeout 5s
            }
        }
    }
}
EOF
    else
        # --- 纯后端反向代理模式 ---
        cat > "${SITE_CONF}" << EOF
# ==========================================
# 业务层：${DOMAIN} (纯后端代理模式)
# ==========================================
 ${DOMAIN} {
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
        # 健康检查
        health_uri /health
        health_interval 10s
        health_timeout 5s
        
        # 传输优化
        transport http {
            read_timeout 0
            write_timeout 0
            dial_timeout 5s
        }
    }
}
EOF
    fi

    # 4. 创建软链接启用站点 (类似 Nginx 的 ln -s)
    ln -sf "${SITES_AVAIL_DIR}/${DOMAIN}.conf" "${SITES_ENABLED_DIR}/${DOMAIN}.conf"

    # 5. 生成主入口 Caddyfile (仅负责全局和引入)
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

    echo -e "${GREEN}[5/6] 启动服务并设置开机自启...${NC}"
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    systemctl restart ${SERVICE_NAME}
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

    CHECK_RESULT=0
    for i in {1..8}; do
        sleep 5
        CERT_ISSUER=$(echo | openssl s_client -connect localhost:443 -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
        
        if echo "$CERT_ISSUER" | grep -qi "Let's Encrypt\|R3\|E1"; then
            echo -e "${GREEN}✅ 恭喜！SSL 证书申请成功且已生效！${NC}"
            CHECK_RESULT=1
            break
        fi
    done

    if [ $CHECK_RESULT -eq 0 ]; then
        echo -e "${YELLOW}⚠️ 证书可能仍在申请中或申请失败。${NC}"
        echo -e "${YELLOW}常见原因：1. 域名未解析到本机IP  2. 阿里云AK/SK权限不足  3. 防火墙未放行80/443端口${NC}"
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
    echo -e "访问地址:   ${GREEN}https://${DOMAIN}${NC}"

    if [ -n "${FRONTEND}" ]; then
        echo -e "运行模式:   ${GREEN}前后端分离托管${NC}"
        echo -e "前端目录:   ${GREEN}${FRONTEND}${NC} (请将打包后的 dist 文件放入此目录)"
        echo -e "后端接口:   ${GREEN}https://${DOMAIN}/api/* -> ${BACKEND}${NC}"
    else
        echo -e "运行模式:   ${GREEN}纯后端反向代理${NC}"
        echo -e "后端代理:   ${GREEN}https://${DOMAIN} -> ${BACKEND}${NC}"
    fi

    echo ""
    echo -e "${BLUE}📊 监控指标:${NC}"
    echo -e "已内置 Prometheus 指标采集。在服务器本机执行以下命令获取："
    echo -e "  ${YELLOW}curl http://localhost:2019/metrics${NC}"

    echo ""
    echo -e "${BLUE}📁 企业级目录架构说明:${NC}"
    echo -e "主配置:     ${CONF_DIR}/Caddyfile (仅管全局和 import)"
    echo -e "中间件层:   ${CONF_DIR}/snippets/ (存放安全头、代理头等通用片段)"
    echo -e "业务层:     ${CONF_DIR}/sites-available/ (存放具体域名的完整配置)"
    echo -e "启停控制:   ${CONF_DIR}/sites-enabled/ (软链接，删除链接即下线域名，类似 Nginx)"

    echo ""
    echo -e "${BLUE}🛠️  日常运维命令:${NC}"
    echo -e "重载配置:   ${YELLOW}systemctl reload caddy${NC}"
    echo -e "新增站点:   1. 在 ${SITES_AVAIL_DIR} 写新域名conf"
    echo -e "            2. 执行: ln -s ${SITES_AVAIL_DIR}/new.conf ${SITES_ENABLED_DIR}/"
    echo -e "            3. 执行: systemctl reload caddy"
    echo -e "下线站点:   ${YELLOW}rm ${SITES_ENABLED_DIR}/${DOMAIN}.conf && systemctl reload caddy${NC}"
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