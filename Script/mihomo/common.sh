#!/bin/bash

# ---------------------------------
# script : 公共函数库
# desc   : 包含系统检测、网络处理等公共函数
# date   : 2025-07-15
# author : Grok
# ---------------------------------

# 终止脚本执行遇到错误时退出，并启用管道错误检测
set -e -o pipefail

# 颜色变量
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
blue="\033[34m"
cyan="\033[36m"
reset="\033[0m"

# 检查是否以 root 权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${red}请以 root 权限运行此脚本（使用 sudo）${reset}"
        exit 1
    fi
}

# 系统检测
check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                distro="$ID"
                pkg_update="apt update && apt upgrade -y"
                pkg_install="apt install -y"
                service_enable() { systemctl enable mihomo; }
                service_restart() { systemctl daemon-reload; systemctl start mihomo; }
                ;;
            alpine)
                distro="alpine"
                pkg_update="apk update && apk upgrade"
                pkg_install="apk add"
                service_enable() { rc-update add mihomo default; }
                service_restart() { rc-service mihomo restart; }
                ;;
            fedora)
                distro="fedora"
                pkg_update="dnf upgrade --refresh -y"
                pkg_install="dnf install -y"
                service_enable() { systemctl enable mihomo; }
                service_restart() { systemctl daemon-reload; systemctl start mihomo; }
                ;;
            arch)
                distro="arch"
                pkg_update="pacman -Syu --noconfirm"
                pkg_install="pacman -S --noconfirm"
                service_enable() { systemctl enable mihomo; }
                service_restart() { systemctl daemon-reload; systemctl start mihomo; }
                ;;
            *)
                echo -e "${red}不支持的系统：${ID}${reset}"
                exit 1
                ;;
        esac
    else
        echo -e "${red}无法识别当前系统类型${reset}"
        exit 1
    fi
    export distro
}

# 网络检测
check_network() {
    use_cdn=false
    if ! curl -sI --fail --connect-timeout 3 --retry 2 https://www.google.com > /dev/null; then
        use_cdn=true
        echo -e "${yellow}网络连接不稳定，将使用 CDN 加速${reset}"
    fi
    export use_cdn
}

# 获取可用的 URL
get_url() {
    local url=$1
    local final_url
    if [ "$use_cdn" = true ]; then
        final_url="https://gh-proxy.com/$url"
        if ! curl -sI --fail --connect-timeout 3 --retry 2 -L "$final_url" -o /dev/null; then
            final_url="https://github.boki.moe/$url"
        fi
    else
        final_url="$url"
    fi
    if ! curl -sI --fail --connect-timeout 3 --retry 2 -L "$final_url" -o /dev/null; then
        echo -e "${red}无法连接到 $url，请检查网络或稍后重试${reset}" >&2
        return 1
    fi
    echo "$final_url"
}

# 获取系统架构
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
    export arch arch_raw
}

# 获取网络信息
get_network_info() {
    local default_iface ipv4 ipv6
    default_iface=$(ip route | awk '/default/ {print $5}' | head -n 1)
    ipv4=$(ip addr show "$default_iface" | awk '/inet / {print $2}' | cut -d/ -f1)
    ipv6=$(ip addr show "$default_iface" | awk '/inet6 / {print $2}' | cut -d/ -f1)
    echo "$default_iface $ipv4 $ipv6"
}