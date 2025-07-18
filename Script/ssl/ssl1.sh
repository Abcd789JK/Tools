#!/bin/bash

# === 脚本信息 ===
echo "----------------------------------------------------"
echo "SSL 证书安装脚本 - 使用 acme.sh 通过 Cloudflare DNS 申请证书"
echo "版本: 1.2"
echo "----------------------------------------------------"

# === 定义变量 ===
LOG_FILE="/var/log/ssl_install_$(date +%Y%m%d_%H%M%S).log"
ACME_HOME="/root/.acme.sh"
ACME_PATH="${ACME_HOME}/acme.sh"
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
BACKUP_DIR="/etc/ssl/backup"
DNS_WAIT_TIME=30  # DNS 传播等待时间（秒）

# === 日志记录函数 ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === 检查 root 权限 ===
if [ "$(id -u)" -ne 0 ]; then
    log "错误：请使用 root 权限运行此脚本！"
    exit 1
fi

# === 创建日志文件 ===
touch "$LOG_FILE" || {
    log "错误：无法创建日志文件 $LOG_FILE"
    exit 1
}
chmod 600 "$LOG_FILE"

# === 安装依赖 ===
log "正在检查并安装依赖..."
if ! command -v curl >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
    apt update -y >> "$LOG_FILE" 2>&1 || {
        log "错误：无法更新包列表"
        exit 1
    }
    apt install -y socat curl >> "$LOG_FILE" 2>&1 || {
        log "错误：无法安装依赖包"
        exit 1
    }
else
    log "依赖已安装"
fi

# === 安装或更新 acme.sh ===
if [ ! -f "$ACME_PATH" ]; then
    log "正在安装 acme.sh..."
    curl https://get.acme.sh | sh >> "$LOG_FILE" 2>&1 || {
        log "错误：acme.sh 安装失败"
        exit 1
    }
else
    log "acme.sh 已安装，检查更新..."
    "$ACME_PATH" --upgrade >> "$LOG_FILE" 2>&1 || log "警告：acme.sh 更新失败"
fi

# 加载 acme.sh 环境变量
if [ -f "${ACME_HOME}/acme.sh.env" ]; then
    source "${ACME_HOME}/acme.sh.env" >> "$LOG_FILE" 2>&1 || {
        log "错误：无法加载 acme.sh 环境变量"
        exit 1
    }
else
    log "错误：acme.sh 环境文件不存在"
    exit 1
fi

# === 设置默认 CA ===
log "设置 Let's Encrypt 为默认证书颁发机构..."
"$ACME_PATH" --set-default-ca --server letsencrypt >> "$LOG_FILE" 2>&1 || {
    log "错误：无法设置默认 CA"
    exit 1
}

# === 获取用户输入 ===
log "请提供以下信息："
while true; do
    read -p "请输入你的 Cloudflare API Token: " CF_TOKEN
    [ -n "$CF_TOKEN" ] && break
    log "错误：API Token 不能为空"
done

while true; do
    read -p "请输入你的 Cloudflare 账号 ID: " CF_ACCOUNT_ID
    [ -n "$CF_ACCOUNT_ID" ] && break
    log "错误：账号 ID 不能为空"
done

while true; do
    read -p "请输入你要申请证书的域名 (例如 example.com): " DOMAIN
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        break
    else
        log "错误：请输入有效的域名"
    fi
done

# === 设置 Cloudflare 环境变量 ===
log "设置 Cloudflare 环境变量..."
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"

# === 验证 Cloudflare API Token（简单检查） ===
log "验证 Cloudflare API Token..."
if ! curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $CF_TOKEN" | grep -q '"success":true'; then
    log "错误：无效的 Cloudflare API Token"
    exit 1
fi

# === 备份现有证书 ===
if [ -d "$CERT_DIR" ] && ls "$CERT_DIR"/*.crt >/dev/null 2>&1; then
    log "备份现有证书..."
    mkdir -p "$BACKUP_DIR" || {
        log "错误：无法创建备份目录 $BACKUP_DIR"
        exit 1
    }
    tar -czf "$BACKUP_DIR/ssl_backup_$(date +%Y%m%d_%H%M%S).tar.gz" \
        "$CERT_DIR"/*.crt "$KEY_DIR"/*.key >> "$LOG_FILE" 2>&1 || {
        log "警告：证书备份失败，继续执行..."
    }
fi

# === 创建证书和密钥目录 ===
mkdir -p "$CERT_DIR" "$KEY_DIR" || {
    log "错误：无法创建证书目录 $CERT_DIR 或 $KEY_DIR"
    exit 1
}
chmod 700 "$KEY_DIR"

# === 申请证书 ===
log "正在申请证书（等待 $DNS_WAIT_TIME 秒以确保 DNS 传播）..."
"$ACME_PATH" --issue --dns dns_cf -d "$DOMAIN" --dns-sleep "$DNS_WAIT_TIME" --log "$LOG_FILE" >> "$LOG_FILE" 2>&1 || {
    log "错误：证书申请失败，请检查日志 $LOG_FILE"
    exit 1
}

# === 安装证书 ===
log "正在安装证书..."
"$ACME_PATH" --install-cert -d "$DOMAIN" \
    --key-file "$KEY_DIR/$DOMAIN.key" \
    --fullchain-file "$CERT_DIR/$DOMAIN.crt" \
    --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true" >> "$LOG_FILE" 2>&1 || {
    log "错误：证书安装失败，请检查日志 $LOG_FILE"
    exit 1
}

# === 设置证书权限 ===
log "设置证书文件权限..."
chmod 600 "$KEY_DIR/$DOMAIN.key" "$CERT_DIR/$DOMAIN.crt" || {
    log "警告：无法设置证书权限"
}

# === 设置自动续期 ===
log "设置证书自动续期..."
"$ACME_PATH" --cron --home "$ACME_HOME" >> "$LOG_FILE" 2>&1 || {
    log "警告：无法设置自动续期"
}

# === 完成提示 ===
log "----------------------------------------------------"
log "证书安装成功！"
log "证书文件："
log "  私钥: $KEY_DIR/$DOMAIN.key"
log "  证书: $CERT_DIR/$DOMAIN.crt"
log "日志文件: $LOG_FILE"
log "备份文件: $BACKUP_DIR/ssl_backup_*.tar.gz (如存在)"
log "----------------------------------------------------"
log "请配置您的 Web 服务器 (如 Nginx 或 Apache) 使用新证书"
log "建议执行 'systemctl reload nginx' 或 'systemctl reload apache2' 以应用更改"