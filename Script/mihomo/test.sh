#!/bin/bash

# ---------------------------------
# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2025-04-29 10:03:30
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
sh_ver="1.0.5"
use_cdn=false
arch_raw=""       # 架构

# 网络检测
check_network() {
    echo -e "${green}正在检测网络...${reset}"
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || curl -s --connect-timeout 3 https://www.google.com >/dev/null; then
        echo -e "${green}网络正常，无需 CDN${reset}"
        use_cdn=false
    else
        echo -e "${yellow}网络受限，启用 CDN 加速${reset}"
        use_cdn=true
    fi
}

# CDN 处理
get_url() {
    local url=$1
    local final_url
    if [ "$use_cdn" = true ]; then
        echo -e "${yellow}正在尝试 gh-proxy 加速节点...${reset}"
        final_url="https://gh-proxy.com/$url"
        if ! curl -sI --fail --connect-timeout 1 -L "$final_url" -o /dev/null; then
            echo -e "${yellow}gh-proxy 不可用，切换到 github.boki.moe${reset}"
            final_url="https://github.boki.moe/$url"
        fi
    else
        final_url="$url"
    fi
    if ! curl -sI --fail --connect-timeout 1 -L "$final_url" -o /dev/null; then
        echo -e "${red}连接失败, 检查网络或代理站点, 稍后重试${reset}" >&2
        return 1
    fi
    echo "$final_url"
}

# 系统更新及必要插件安装
update_system() {
    echo -e "${green}正在更新系统并安装常用工具...${reset}"
    apt update && apt upgrade -y
    apt install -y curl git wget nano gzip jq unzip yq openssl tzdata
    echo -e "${green}完成！${reset}"
}

# 系统架构获取
get_schema() {
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64)
            arch='amd64'
            ;;
        x86|i686|i386)
            arch='386'
            ;;
        aarch64|arm64)
            arch='arm64'
            ;;
        armv7l)
            arch='armv7'
            ;;
        s390x)
            arch='s390x'
            ;;
        *)
            echo -e "${red}不支持的架构：${arch_raw}${reset}"
            exit 1
            ;;
    esac
}
