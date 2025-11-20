#!/bin/bash

# ---------------------------------
# script : ssl 一键证书申请脚本
# desc   : 证书申请
# date   : 2025-11-20 17:43:38
# author : ChatGPT
# ---------------------------------

# 终止脚本执行遇到错误时退出, 并启用管道错误检测
set -e -o pipefail

# 颜色变量
red="\033[31m"    # 红色
green="\033[32m"  # 绿色
yellow="\033[33m" # 黄色
blue="\033[34m"   # 蓝色
cyan="\033[36m"   # 青色
reset="\033[0m"   # 重置

# 全局变量
sh_ver="1.0.0"

echo -e "${cyan}############################################${reset}"
echo -e "${green}欢迎使用 Cloudflare DNS 证书申请脚本${reset}"
echo -e "${green}本脚本目前只支持使用 DNS 方式申请，合适无 80 和 443 端口的家庭服务器${reset}"
echo -e "${green}后续支持其他方式${reset}"
echo -e "${cyan}############################################${reset}"

# 检查是否有 root 权限
check_root(){
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${red}请以 root 用户运行此脚本! ${reset}"
        exit 1
    fi
}

# 系统更新及插件安装
update_system() {
    echo -e "${green}正在更新系统和安装依赖...${reset}"
    apt update && apt upgrade -y
    apt install -y socat curl
}

# 安装或更新 acme.sh
check_acme(){
    local acme_sh="/root/.acme.sh/acme.sh"
    if [ ! -f "$acme_sh" ]; then
        echo -e "${green}未检测到 acme.sh, 开始安装...${reset}"
        curl -s https://get.acme.sh | sh
        [ -f ~/.bashrc ] && source ~/.bashrc
    else
        echo -e "${green}检测到 acme.sh, 检查更新...${reset}"
        "$acme_sh" --upgrade
    fi
    "$acme_sh" --set-default-ca --server letsencrypt
    echo -e "${red}默认颁发机构已设置为 Let's Encrypt${reset}"
}

# 获取 Cloudflare 信息
get_cloudflare() {
    echo -ne "${green}请输入你的 Cloudflare API Token (输入后不显示 Token): ${reset}"
    read -rsp "" token; echo
    read -rp "$(echo -e "${green}请输入你的 Cloudflare Account 账号 ID: ${reset}")" account_id
    read -rp "$(echo -e "${green}请输入你要申请证书的域名 (如 example.com 或 xxx.example.com): ${reset}")" domain
    export CF_Token="$token"
    export CF_Account_ID="$account_id"
}

# 根据域名类型生成 -d 参数
domain_args() {
    local d_args=()
    if [[ "$domain" == *.*.* ]]; then
        d_args+=("-d" "$domain")
    else
        d_args+=("-d" "$domain" "-d" "*.$domain")
    fi
    echo "${d_args[@]}"
}

# 申请证书
issue_cert() {
    local d_args
    d_args=$(domain_args)
    ssl_dir="/root/ssl"
    local acme_sh="/root/.acme.sh/acme.sh"
    mkdir -p "$ssl_dir"
    "$acme_sh" --issue \
        --dns dns_cf \
        $d_args \
        --key-file "$ssl_dir/$domain.key" \
        --fullchain-file "$ssl_dir/$domain.crt"
    echo -e "${green}恭喜你! 证书申请完成! 已保存到 $ssl_dir 目录${reset}"
    echo -e "${cyan}私钥: $ssl_dir/$domain.key${reset}"
    echo -e "${cyan}证书: $ssl_dir/$domain.crt${reset}"
}

check_root
update_system
check_acme
get_cloudflare
issue_cert
