#!/bin/bash
# ==========================================================
# Caddy + AliDNS 生产环境一键离线安装脚本 (支持前后端分离)
# ==========================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认变量
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/caddy"
LOG_DIR="/var/log/caddy"
DATA_DIR="/var/lib/caddy"
SERVICE_NAME="caddy"
BIN_NAME="caddy"

# Makeself 解压路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_BIN="${SCRIPT_DIR}/${BIN_NAME}"

# 用户输入变量
AK=""
SK=""
REGION="cn-hangzhou"
DOMAIN=""
BACKEND=""
FRONTEND=""  # 新增：前端静态文件目录

CONFIG_FILE=""

# ---------------------------------------------------------
# 帮助信息 (已更新)
# ---------------------------------------------------------
show_help() {
    echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
    echo ""
    echo -e "${GREEN}自动化部署集成阿里云 DNS 的 Caddy 反向代理/静态托管服务${NC}"
    echo ""
    echo "Options:"
    echo "  --config <file>       从指定的配置文件中读取参数 (推荐，避免密钥泄露到历史记录)"
    echo "  --ak <string>         阿里云 AccessKey ID"
    echo "  --sk <string>         阿里云 AccessKey Secret"
    echo "  --region <string>     阿里云 Region ID (默认: cn-hangzhou)"
    echo "  --domain <string>     要监听并申请 HTTPS 证书的域名 (如: example.com)"
    echo "  --backend <string>    后端服务地址 (如: 127.0.0.1:8080)"
    echo "  --frontend <path>     前端静态文件绝对路径 (如: /var/www/dist)"
    echo "                        - 不填: 纯反向代理到后端"
    echo "                        - 填写: 托管前端，并将后端代理挂载到 /api/* 路径"
    echo "  --help, -h            显示本帮助信息"
    echo ""
    echo "配置文件格式示例:"
    echo "  AK=LTAI5txxxxxxxxxx"
    echo "  SK=xxxxxxxxxxxxxxxxx"
    echo "  DOMAIN=api.example.com"
    echo "  BACKEND=127.0.0.1:8080"
    echo "  FRONTEND=/var/www/html/dist"
    echo "  REGION=cn-hangzhou"
    exit 0
}

# ---------------------------------------------------------
# 加载配置文件 (已更新)
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
        if [[ ! -z "$key" && ! "$key" =~ ^# ]]; then
            case "$key" in
                AK) AK="$value" ;;
                SK) SK="$value" ;;
                DOMAIN) DOMAIN="$value" ;;
                BACKEND) BACKEND="$value" ;;
                FRONTEND) FRONTEND="$value" ;;  # 新增
                REGION) REGION="$value" ;;
            esac
        fi
    done < "${CONFIG_FILE}"
}

# ---------------------------------------------------------
# 参数解析 (已更新)
# ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --ak) AK="$2"; shift 2 ;;
        --sk) SK="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --backend) BACKEND="$2"; shift 2 ;;
        --frontend) FRONTEND="$2"; shift 2 ;;  # 新增
        -h|--help) show_help ;;
        *) echo -e "${RED}未知参数: $1${NC}"; show_help ;;
    esac
done

[ -n "${CONFIG_FILE}" ] && load_config

# ---------------------------------------------------------
# 交互式向导 (已更新)
# ---------------------------------------------------------
if [ -z "${DOMAIN}" ] || [ -z "${AK}" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Caddy + AliDNS 交互式部署向导${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    read -p "请输入要绑定的域名 (例如 api.example.com): " DOMAIN
    [ -z "$DOMAIN" ] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }
    
    read -p "请输入后端服务地址 (例如 127.0.0.1:8080): " BACKEND
    [ -z "$BACKEND" ] && { echo -e "${RED}后端地址不能为空${NC}"; exit 1; }
    
    read -p "请输入前端静态文件目录 (直接回车跳过，表示纯反向代理): " INPUT_FRONTEND
    FRONTEND=${INPUT_FRONTEND:-""}
    
    echo -e "${YELLOW}[阿里云 API 凭证配置]${NC}"
    read -p "请输入 AccessKey ID: " AK
    [ -z "$AK" ] && { echo -e "${RED}AK不能为空${NC}"; exit 1; }
    
    read -sp "请输入 AccessKey Secret (输入不显示): " SK
    echo ""
    [ -z "$SK" ] && { echo -e "${RED}SK不能为空${NC}"; exit 1; }
    
    read -p "请输入 Region ID (默认 cn-hangzhou 直接回车): " INPUT_REGION
    REGION=${INPUT_REGION:-cn-hangzhou}
fi

# ---------------------------------------------------------
# 数据清洗与预检查 (保持不变)
# ---------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 权限运行 (使用 sudo ./xxx.run)${NC}"
    exit 1
fi

if [ ! -f "${OFFLINE_BIN}" ]; then
    echo -e "${RED}错误：离线安装包损坏，找不到二进制文件${NC}"
    exit 1
fi

DOMAIN=$(echo "${DOMAIN}" | sed 's|^https\?://||' | sed 's|/.*||')
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}错误：域名格式不正确 (${DOMAIN})${NC}"
    exit 1
fi

# 前端目录校验（如果填了的话）
if [ -n "${FRONTEND}" ]; then
    if [ ! -d "${FRONTEND}" ]; then
        echo -e "${YELLOW}警告：前端目录 ${FRONTEND} 不存在，将为您自动创建，请稍后自行上传文件。${NC}"
        mkdir -p "${FRONTEND}"
    fi
fi

echo -e "${YELLOW}预检：检查 80/443 端口占用情况...${NC}"
PORT_BLOCKED=0
if ss -tlnp | grep -q ':80\b' && ! ss -tlnp | grep -q 'caddy'; then
    echo -e "${RED}警告：80 端口被其他程序占用！${NC}"
    PORT_BLOCKED=1
fi
if ss -tlnp | grep -q ':443\b' && ! ss -tlnp | grep -q 'caddy'; then
    echo -e "${RED}警告：443 端口被其他程序占用！${NC}"
    PORT_BLOCKED=1
fi
if [ $PORT_BLOCKED -eq 1 ]; then
    echo -e "${RED}请先停止占用端口的程序 (如 nginx: systemctl stop nginx)，否则 Caddy 将无法启动。${NC}"
    exit 1
fi

# ---------------------------------------------------------
# 核心安装逻辑 (保持不变)
# ---------------------------------------------------------
echo -e "${GREEN}[1/5] 停止旧服务并备份配置...${NC}"
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
[ -f "${CONF_DIR}/Caddyfile" ] && cp "${CONF_DIR}/Caddyfile" "${CONF_DIR}/Caddyfile.bak.$(date +%s)"

echo -e "${GREEN}[2/5] 初始化系统环境...${NC}"
id -u ${SERVICE_NAME} &>/dev/null || useradd -r -s /sbin/nologin ${SERVICE_NAME}
mkdir -p "${CONF_DIR}" "${LOG_DIR}" "${DATA_DIR}"
chown -R ${SERVICE_NAME}:${SERVICE_NAME} "${LOG_DIR}" "${DATA_DIR}"

echo -e "${GREEN}[3/5] 部署二进制与系统服务...${NC}"
cp -f "${OFFLINE_BIN}" "${INSTALL_DIR}/${BIN_NAME}"
chmod 755 "${INSTALL_DIR}/${BIN_NAME}"
setcap cap_net_bind_service=+ep "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null || true
if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv "${INSTALL_DIR}/${BIN_NAME}" >/dev/null 2>&1 || true
fi
cp -f "${SCRIPT_DIR}/caddy.service" /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload

# ---------------------------------------------------------
# 生成 Caddyfile (核心逻辑变更：智能适配前后端)
# ---------------------------------------------------------
echo -e "${GREEN}[4/5] 生成生产级 Caddyfile 配置...${NC}"

# 先写入全局配置
cat > "${CONF_DIR}/Caddyfile" << EOF
{
    dns alidns {
        access_key_id     ${AK}
        access_key_secret ${SK}
        region_id         ${REGION}
    }

    log {
        format json
        level INFO
    }
}

EOF

# 判断是否配置了前端目录
if [ -n "${FRONTEND}" ]; then
    # --- 前后端分离模式 ---
    # 1. 把前端目录的所有权交给 caddy 用户，防止 403 Forbidden
    chown -R ${SERVICE_NAME}:${SERVICE_NAME} "${FRONTEND}"
    
    cat >> "${CONF_DIR}/Caddyfile" << EOF
 ${DOMAIN} {
    tls {
        dns alidns {
            propagation_timeout 5m
            resolvers 223.5.5.5
        }
    }

    # 托管前端静态文件
    root * ${FRONTEND}
    try_files {path} /index.html
    file_server

    # 将后端 API 代理到 /api 路径下
    reverse_proxy /api/* ${BACKEND}
}
EOF
else
    # --- 纯后端反向代理模式 ---
    cat >> "${CONF_DIR}/Caddyfile" << EOF
 ${DOMAIN} {
    tls {
        dns alidns {
            propagation_timeout 5m
            resolvers 223.5.5.5
        }
    }

    # 纯反向代理到后端
    reverse_proxy ${BACKEND}
}
EOF
fi

chown ${SERVICE_NAME}:${SERVICE_NAME} "${CONF_DIR}/Caddyfile"
chmod 600 "${CONF_DIR}/Caddyfile"

echo -e "${GREEN}[5/5] 启动服务并设置开机自启...${NC}"
systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
systemctl restart ${SERVICE_NAME}

# ---------------------------------------------------------
# 证书与服务状态验证 (保持不变)
# ---------------------------------------------------------
echo ""
echo -e "${YELLOW}正在验证服务与证书状态 (通常需要 10-30 秒)...${NC}"

sleep 3
if ! systemctl is-active --quiet ${SERVICE_NAME}; then
    echo -e "${RED}❌ Caddy 服务启动失败！${NC}"
    echo -e "${RED}请检查配置语法：caddy validate --config ${CONF_DIR}/Caddyfile${NC}"
    echo -e "${RED}或查看详细日志：journalctl -u caddy -n 20 --no-pager${NC}"
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
    echo -e "${YELLOW}常见原因：1. 域名未解析到本机IP 2. 阿里云AK/SK权限不足 3. 防火墙未放行443端口${NC}"
    echo -e "${YELLOW}你可以稍后手动检查：journalctl -u caddy -f${NC}"
fi

# ---------------------------------------------------------
# 完成 (更新输出提示)
# ---------------------------------------------------------
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  部署完成总结${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "访问地址: ${GREEN}https://${DOMAIN}${NC}"

if [ -n "${FRONTEND}" ]; then
    echo -e "运行模式: ${GREEN}前后端分离${NC}"
    echo -e "前端目录: ${GREEN}${FRONTEND}${NC} (请将 Vue/React 打包后的 dist 文件放入此目录)"
    echo -e "后端接口: ${GREEN}https://${DOMAIN}/api/* -> ${BACKEND}${NC}"
else
    echo -e "运行模式: ${GREEN}纯反向代理${NC}"
    echo -e "后端代理: ${GREEN}https://${DOMAIN} -> ${BACKEND}${NC}"
fi

echo -e "配置文件: ${GREEN}${CONF_DIR}/Caddyfile${NC} (权限已锁定为600)"
echo -e "查看日志: ${GREEN}journalctl -u caddy -f${NC}"
echo "" 