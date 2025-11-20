#!/bin/bash

# ---------------------------------
# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2025-11-20 11:49:15
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
distro="unknown"  # 系统类型
arch=""           # 系统架构
arch_raw=""       # 原始架构

# 系统检测
check_distro() {
    [[ -f /etc/os-release ]] || { echo -e "${red}无法识别当前系统类型${reset}"; exit 1; }
    . /etc/os-release
    case "$ID" in
        debian|ubuntu)
            distro="$ID"
            pkg_update="apt update && apt upgrade -y"
            pkg_install="apt install -y"
            ;;
        fedora)
            distro="fedora"
            pkg_update="dnf upgrade --refresh -y"
            pkg_install="dnf install -y"
            ;;
        arch)
            distro="arch"
            pkg_update="pacman -Syu --noconfirm"
            pkg_install="pacman -S --noconfirm"
            ;;
        alpine)
            distro="alpine"
            pkg_update="apk update && apk upgrade"
            pkg_install="apk add"
            service_enable() { rc-update add mihomo default; }
            service_restart() { rc-service mihomo restart; }
            return 0
            ;;
        *)
            echo -e "${red}不支持的系统：$ID${reset}"
            exit 1
            ;;
    esac
    service_enable() { systemctl enable mihomo; }
    service_restart() { systemctl daemon-reload && systemctl restart mihomo; }
}

# 网络检测
check_network() {
    if ! curl -sI --fail --connect-timeout 1 https://www.google.com > /dev/null; then
        use_cdn=true
    fi
}

# 链接处理
get_url() {
    local url="$1"
    local candidate
    if [[ $use_cdn == true ]]; then
        for prefix in "https://gh-proxy.com" "https://github.boki.moe"; do
            candidate="${prefix}/${url}"
            curl -sI --fail --connect-timeout 1 -L "$candidate" -o /dev/null && echo "$candidate" && return 0
        done
    else
        candidate="$url"
        curl -sI --fail --connect-timeout 1 -L "$candidate" -o /dev/null && echo "$candidate" && return 0
    fi
    echo -e "${red}连接失败，请检查网络或代理站点${reset}" >&2
    return 1
}

# 系统更新及插件安装
update_system() {
    eval "$pkg_update"
    eval "$pkg_install curl git gzip wget nano iptables tzdata jq unzip yq openssl"
}

# 系统架构
get_schema() {
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64)              arch=amd64  ;;
        i?86)                arch=386    ;;
        aarch64|arm64)       arch=arm64  ;;
        armv7l)              arch=armv7  ;;
        s390x)               arch=s390x  ;;
        *)
            echo -e "${red}不支持的架构: ${arch_raw}${reset}"
            exit 1
            ;;
    esac
}

# IPv4/IPv6 转发检查
check_ip_forward() {
    local sysctl_file="/etc/sysctl.d/99-ip-forward.conf"
    [ -f "$sysctl_file" ] || touch "$sysctl_file"
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    grep -Eq '^\s*net\.ipv4\.ip_forward\s*=\s*1' "$sysctl_file" || echo "net.ipv4.ip_forward=1" >> "$sysctl_file"
    grep -Eq '^\s*net\.ipv6\.conf\.all\.forwarding\s*=\s*1' "$sysctl_file" || echo "net.ipv6.conf.all.forwarding=1" >> "$sysctl_file"
    sysctl -p "$sysctl_file" > /dev/null
}

# 版本获取
download_version() {
    local version_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt"
    version=$(curl -sSL "$(get_url "$version_url")") || {
        echo -e "${red}获取 mihomo 远程版本失败${reset}"
        exit 1
    }
}

# 软件下载
download_mihomo() {
    download_version
    local version_file="/root/mihomo/version.txt"
    local filename="mihomo-linux-${arch}-${version}.gz"
    [ "$arch" = "amd64" ] && filename="mihomo-linux-${arch}-compatible-${version}.gz"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/${filename}"
    wget -O "$filename" "$(get_url "$download_url")" || {
        echo -e "${red}mihomo 下载失败，请检查网络后重试${reset}"
        exit 1
    }
    gunzip "$filename" || {
        echo -e "${red}mihomo 解压失败${reset}"
        exit 1
    }
    if [ -f "mihomo-linux-${arch}-compatible-${version}" ]; then
        mv "mihomo-linux-${arch}-compatible-${version}" mihomo
    elif [ -f "mihomo-linux-${arch}-${version}" ]; then
        mv "mihomo-linux-${arch}-${version}" mihomo
    else
        echo -e "${red}找不到解压后的文件${reset}"
        exit 1
    fi
    chmod +x mihomo
    echo "$version" > "$version_file"
}

# 服务配置
download_service() {
    if [ "$distro" = "alpine" ]; then
        local service_file="/etc/init.d/mihomo"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/mihomo.openrc"
        wget -O "$service_file" "$(get_url "$service_url")" || {
            echo -e "${red}系统服务下载失败，请检查网络后重试${reset}"
            exit 1
        }
        chmod +x "$service_file"
        service_enable
    else
        local service_file="/etc/systemd/system/mihomo.service"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/mihomo.service"
        wget -O "$service_file" "$(get_url "$service_url")" || {
            echo -e "${red}系统服务下载失败，请检查网络后重试${reset}"
            exit 1
        }
        chmod +x "$service_file"
        service_enable
    fi
}

# 管理面板
download_wbeui() {
    local wbe_file="/root/mihomo"
    local filename="gh-pages.zip"
    local url_za="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
    wget -O "$filename" "$(get_url "$url_za")" || {
        echo -e "${red}管理面板下载失败，请检查网络后重试${reset}"
        exit 1
    }
    unzip -oq "$filename" && rm "$filename" || {
        exit 1
    }
    extracted_folder=$(ls -d "$wbe_file"/*-gh-pages | head -n 1)
    mv "$extracted_folder" "$wbe_file/ui" || {
        exit 1
    }
}

# 管理脚本
download_shell() {
    local shell_file="/usr/bin/mihomo"
    local sh_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/mihomo/mihomo.sh"
    [ -f "$shell_file" ] && rm -f "$shell_file"
    wget -O "$shell_file" "$(get_url "$sh_url")" || {
        echo -e "${red}管理脚本下载失败，请检查网络后重试${reset}"
        exit 1
    }
    chmod +x "$shell_file"
    hash -r
}

# IP 地址获取
get_network_info() {
  local default_iface ipv4 ipv6
  default_iface=$(ip route | awk '/default/ {print $5}' | head -n 1)
  ipv4=$(ip addr show "$default_iface" | awk '/inet / {print $2}' | cut -d/ -f1)
  ipv6=$(ip addr show "$default_iface" | awk '/inet6 / {print $2}' | cut -d/ -f1)
  echo "$default_iface $ipv4 $ipv6"
}

# 新增订阅
config_proxy() {
  local providers="proxy-providers:"
  local subscription=1
  while true; do
    echo -e "${cyan}正在添加第 ${subscription} 个机场配置${reset}" >&2
    read -p "$(echo -e "${green}请输入机场的订阅连接: ${reset}")" subscription_url
    read -p "$(echo -e "${blue}请输入机场的名称: ${reset}")" subscription_name
    providers="${providers}
  provider_$(printf "%02d" $subscription):
    url: \"${subscription_url}\"
    type: http
    interval: 86400
    health-check: {enable: true, url: "https://www.gstatic.com/generate_204", interval: 300}
    override:
      additional-prefix: \"[${subscription_name}]\""
    subscription=$((subscription + 1))
    read -p "$(echo -e "${yellow}是否继续输入订阅？按回车继续，输入 n/N 结束: ${reset}")" cont
    if [[ "$cont" =~ ^[nN]$ ]]; then
      break
    fi
  done
  echo "$providers"
}

# 配置文件
config_mihomo() {
  local root_folder="/root/mihomo"
  local config_file="/root/mihomo/config.yaml"
  local remote_config_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Config/mihomo.yaml"
  mkdir -p "$root_folder"
  read default_iface ipv4 ipv6 <<< "$(get_network_info)"
  wget -O "$config_file" "$(get_url "$remote_config_url")" || { 
    echo -e "${red}配置文件下载失败${reset}"
    exit 1
  }
  local proxy_providers=$(config_proxy)
  awk -v providers="$proxy_providers" '
    /^# 机场配置/ { print; print providers; next }
    { print }
  ' "$config_file" > temp.yaml && mv temp.yaml "$config_file"
  service_restart
  echo -e "${green}配置完成，配置文件已保存到：${yellow}${config_file}${reset}"
  echo -e "${green}mihomo 配置完成，正在启动中${reset}"
  echo -e "${red}管理面板地址和管理命令${reset}"
  echo -e "${cyan}=========================${reset}"
  echo -e "${green}http://$ipv4:9090/ui${reset}"
  echo -e ""
  echo -e "${green}输入: ${yellow}mihomo ${green}进入管理菜单${reset}"
  echo -e "${cyan}=========================${reset}"
  echo -e "${green}mihomo 已成功启动并设置为开机自启${reset}"
}

# 安装程序
install_mihomo() {
    local folders="/root/mihomo"
    rm -rf "$folders"
    mkdir -p "$folders" && cd "$folders"
    check_ip_forward
    echo -e "${yellow}当前系统版本：${reset}[ ${green}${distro}${reset} ]"
    get_schema
    echo -e "${yellow}当前系统架构：${reset}[ ${green}${arch_raw}${reset} ]"
    download_version
    echo -e "${yellow}当前软件版本：${reset}[ ${green}${version}${reset} ]"
    echo -e "${green}开始下载 mihomo 请等待${reset}"
    download_mihomo
    echo -e "${green}开始下载配置服务请等待${reset}"
    download_service
    echo -e "${green}开始下载管理 UI 请等待${reset}"
    download_wbeui
    echo -e "${green}开始下载菜单脚本请等待${reset}"
    download_shell
    echo -e "${green}恭喜你! mihomo 已经安装完成${reset}"
    echo
    echo -e "${yellow}配置文件，你可以选择使用我的，也可以选择自己上传${reset}"
    echo
    echo -e "${red}输入 y/Y 下载默认配置文件${reset}"
    echo
    echo -e "${red}输入 n/N 取消下载默认配置, 需要上传你准备好的配置文件${reset}"
    echo
    echo -e "${red}把你准备好的配置文件上传到 ${folders} 目录下(文件名必须为 config.yaml)${reset}"
    echo
    read -p "$(echo -e "${yellow}请输入选择(y/n) [默认: y]: ${reset}")" confirm
    confirm=${confirm:-y}
    case "$confirm" in
        [Yy]*)
            config_mihomo
            ;;
         *)
            echo -e "${green}跳过配置文件下载${reset}"
            ;;
    esac
    rm -f /root/install.sh
}

# 主菜单
check_distro
check_network
update_system
check_ip_forward
install_mihomo