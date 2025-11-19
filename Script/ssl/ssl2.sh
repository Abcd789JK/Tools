#!/bin/bash

# ======================================================
# ACME.sh + Cloudflare DNS API 证书申请脚本
# ======================================================

echo "----------------------------------------------------"
echo "ACME.sh SSL 证书申请脚本（Cloudflare DNS）"
echo "----------------------------------------------------"

# === 必须以 root 身份运行 ===
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请以 root 用户运行此脚本。"
  exit 1
fi

# === 安装依赖 ===
echo "正在安装依赖（socat、curl）..."
apt update -y
apt install -y socat curl

# === 检查 acme.sh ===
ACME_BIN="/root/.acme.sh/acme.sh"

if [ ! -f "$ACME_BIN" ]; then
  echo "正在安装 acme.sh..."
  curl -s https://get.acme.sh | sh

  # 加载 acme.sh 写入的环境变量
  if [ -f ~/.bashrc ]; then
    source ~/.bashrc
  fi
else
  echo "acme.sh 已安装，跳过安装步骤。"
fi

# 再次确认是否安装成功
if [ ! -f "$ACME_BIN" ]; then
  echo "错误：acme.sh 安装失败，未找到 $ACME_BIN"
  exit 1
fi

# 设置默认 CA 为 Let's Encrypt（可改为 zerossl）
$ACME_BIN --set-default-ca --server letsencrypt

# === 用户输入 ===
echo ""
echo "请输入 Cloudflare 相关信息："
read -rp "API Token: " CF_TOKEN
read -rp "Account ID: " CF_ACCOUNT_ID
read -rp "证书域名（如 example.com）: " domain

# 输入校验
if [[ -z "$CF_TOKEN" || -z "$CF_ACCOUNT_ID" || -z "$domain" ]]; then
  echo "错误：API Token、Account ID 或域名不能为空。"
  exit 1
fi

# === 设置 Cloudflare 环境变量 ===
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"

# === 开始申请证书 ===
echo ""
echo "正在申请证书（DNS-01 验证）..."

$ACME_BIN --issue --dns dns_cf -d "$domain"
if [ $? -ne 0 ]; then
  echo "错误：证书申请失败，请检查 API Token 权限和域名解析。"
  exit 1
fi

# === 安装证书 ===
echo "证书申请成功，正在安装证书..."

INSTALL_DIR="/root/ssl"
mkdir -p "$INSTALL_DIR"

$ACME_BIN --install-cert -d "$domain" \
  --key-file       "$INSTALL_DIR/server.key" \
  --fullchain-file "$INSTALL_DIR/server.crt"

if [ $? -ne 0 ]; then
  echo "错误：证书安装失败。"
  exit 1
fi

echo "----------------------------------------------------"
echo "证书安装完成。文件位于："
echo "  $INSTALL_DIR/server.key"
echo "  $INSTALL_DIR/server.crt"
echo "ACME.sh 会自动执行续期，无需额外配置。"
echo "----------------------------------------------------"
