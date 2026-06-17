#!/bin/bash

# ======================================================
# ACME.sh + Cloudflare DNS 证书申请脚本
# 专业规范版 - 遵循 Shell 最佳实践
# ======================================================

# 终止脚本执行遇到错误时退出, 并启用管道错误检测
set -e -o pipefail

# --------------------- 配置区 ---------------------
ACME_BIN="/root/.acme.sh/acme.sh"
INSTALL_DIR="/root/ssl"

# --------------------- 检查 root 权限 ---------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 用户运行此脚本。"
    exit 1
fi

# --------------------- 安装依赖 ---------------------
echo "正在安装必要依赖..."
apt update -y >/dev/null 2>&1
apt install -y socat curl >/dev/null 2>&1

# --------------------- 检查并安装 acme.sh ---------------------
acme_bin="/root/.acme.sh/acme.sh"

if [ ! -f "$acme_bin" ]; then
    echo "正在安装 acme.sh..."
    curl -s https://get.acme.sh | sh
    source ~/.bashrc 2>/dev/null || true
else
    echo "acme.sh 已安装，正在升级至最新版本..."
    "$acme_bin" --upgrade >/dev/null 2>&1
fi

# 设置默认 CA 为 Let's Encrypt
"$acme_bin" --set-default-ca --server letsencrypt

# --------------------- 用户输入 ---------------------
echo ""
echo "请输入 Cloudflare 相关信息："
read -rp "API Token: " CF_TOKEN
read -rp "Account ID: " CF_ACCOUNT_ID
read -rp "Zone ID（可选，直接回车跳过）: " CF_ZONE_ID
read -rp "域名（支持通配符，如 *.example.com）: " DOMAIN

# 输入校验
if [[ -z "$CF_TOKEN" || -z "$CF_ACCOUNT_ID" || -z "$DOMAIN" ]]; then
    echo "错误: API Token、Account ID 和域名不能为空。"
    exit 1
fi

# --------------------- 设置环境变量 ---------------------
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"
[[ -n "$CF_ZONE_ID" ]] && export CF_Zone_ID="$CF_ZONE_ID"

# --------------------- 申请证书 ---------------------
echo ""
echo "正在申请证书（DNS-01 验证）..."
"$acme_bin" --issue --dns dns_cf -d "$DOMAIN"

# --------------------- 安装证书 ---------------------
echo "证书申请成功，正在安装证书..."
mkdir -p "$INSTALL_DIR"

"$acme_bin" --install-cert -d "$DOMAIN" \
    --key-file       "$INSTALL_DIR/server.key" \
    --fullchain-file "$INSTALL_DIR/server.crt"

# --------------------- 完成提示 ---------------------
echo "----------------------------------------------------"
echo "证书安装完成！"
echo "私钥文件:     $INSTALL_DIR/server.key"
echo "证书文件:     $INSTALL_DIR/server.crt"
echo ""
echo "ACME.sh 已自动配置证书续期任务，无需额外操作。"
echo "----------------------------------------------------"