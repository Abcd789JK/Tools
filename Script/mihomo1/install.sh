#!/bin/bash

# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2025-04-29 10:03:30
# author : ChatGPT

# === 终止脚本执行遇到错误时退出, 并启用管道错误检测 ===
set -e -o pipefail

# === 全局变量 ===
sh_ver="1.0.1"

# === 检查 root 权限 ===
if [ "$(id -u)" -ne 0 ]; then
    log "错误：请使用 root 权限运行此脚本！"
    exit 1
fi

# === 系统更新和工具安装 ===
update_system() {
    log "正在更新软件包索引..."
    apt update

    log "正在升级已安装的软件包..."
    apt upgrade -y

    log "正在安装常用工具..."
    apt install -y curl git gzip wget nano iptables tzdata jq unzip yq openssl

    log "系统更新与软件安装完成。"
}

# === IPv4/IPv6 转发检查 ===
check_ip_forward() {
    local sysctl_file="/etc/sysctl.conf"
    local changed=0

    # 开启 IPv4 转发
    log "检查并启用 IPv4 转发..."
    if ! sysctl net.ipv4.ip_forward | grep -qE '=\s*1'; then
        sysctl -w net.ipv4.ip_forward=1
        changed=1
    fi
    if ! grep -Eq '^\s*net\.ipv4\.ip_forward\s*=\s*1' "$sysctl_file"; then
        echo "net.ipv4.ip_forward=1" >> "$sysctl_file"
        changed=1
    fi

    # 开启 IPv6 转发
    log "检查并启用 IPv6 转发..."
    if ! sysctl net.ipv6.conf.all.forwarding | grep -qE '=\s*1'; then
        sysctl -w net.ipv6.conf.all.forwarding=1
        changed=1
    fi
    if ! grep -Eq '^\s*net\.ipv6\.conf\.all\.forwarding\s*=\s*1' "$sysctl_file"; then
        echo "net.ipv6.conf.all.forwarding=1" >> "$sysctl_file"
        changed=1
    fi

    # 应用 sysctl 变更
    if [ "$changed" -eq 1 ]; then
        log "应用 sysctl 配置..."
        sysctl -p > /dev/null
    else
        log "IP 转发设置已正确，无需更改。"
    fi
}

# === 版本获取 ===
download_version() {
    local version_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt"
    
    log "正在获取最新版本信息..."

    if ! version=$(curl -fsSL "$(get_url "$version_url")"); then
        error "版本信息下载失败，请检查网络连接或 URL 是否正确！"
        exit 1
    fi

    log "获取到版本号：$version"
}

# === 下载 Mihomo ===
download_mihomo() {
    local version_file="/root/mihomo/version.txt"
    local filename="mihomo-linux-amd64-compatible-${version}.gz"
    local binary="mihomo-linux-amd64-compatible-${version}"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/${filename}"

    log "开始下载 Mihomo：$filename"
    if ! wget -O "$filename" "$(get_url "$download_url")"; then
        error "下载失败：$filename"
        exit 1
    fi

    log "正在解压 Mihomo..."
    if ! gunzip -f "$filename"; then
        error "解压失败：$filename"
        exit 1
    fi

    if [ ! -f "$binary" ]; then
        error "解压后的文件不存在：$binary"
        exit 1
    fi

    mv "$binary" mihomo
    chmod +x mihomo

    mkdir -p "$(dirname "$version_file")"
    echo "$version" > "$version_file"

    log "Mihomo $version 下载完成并准备就绪"
}

# === 下载 Mihomo service ===
download_service() {
    local service_file="/etc/systemd/system/mihomo.service"
    local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/mihomo.service"

    log "正在下载 systemd 服务文件..."

    if ! wget -O "$service_file" "$(get_url "$service_url")"; then
        error "系统服务文件下载失败，请检查网络连接或 URL 是否正确"
        exit 1
    fi

    # systemd 的 .service 文件不需要执行权限，但做 chmod 也无害
    chmod 644 "$service_file"

    log "systemd 服务文件已保存至 $service_file"

    service_enable
}

# === 获取 IP 地址 ===
get_network_info() {
    local default_iface ipv4 ipv6

    # 获取默认网卡
    default_iface=$(ip route | awk '/^default/ {print $5}' | head -n 1)
    if [ -z "$default_iface" ]; then
        error "无法检测默认网卡"
        return 1
    fi

    # 获取 IPv4 地址（排除 127.x）
    ipv4=$(ip -4 addr show "$default_iface" | awk '/inet / && $2 !~ /^127/ {print $2}' | cut -d/ -f1 | head -n 1)

    # 获取 IPv6 地址（排除 link-local fe80::）
    ipv6=$(ip -6 addr show "$default_iface" | awk '/inet6 / && $2 !~ /^fe80/ {print $2}' | cut -d/ -f1 | head -n 1)

    log "网卡：$default_iface"
    log "IPv4: ${ipv4:-无}"
    log "IPv6: ${ipv6:-无}"

    echo "$default_iface $ipv4 $ipv6"
}

# download_shell() {
#     local shell_file="/usr/bin/mihomo"
#     local sh_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/mihomo/mihomo.sh"

#     log "准备下载 Mihomo 管理脚本..."

#     # 如果存在旧版本，先删除
#     if [ -f "$shell_file" ]; then
#         log "移除旧版脚本：$shell_file"
#         rm -f "$shell_file"
#     fi

#     # 下载新脚本
#     if ! wget -O "$shell_file" "$(get_url "$sh_url")"; then
#         error "管理脚本下载失败，请检查网络连接或源地址是否可访问。"
#         exit 1
#     fi

#     chmod +x "$shell_file"
#     hash -r

#     log "Mihomo 管理脚本已安装至 $shell_file"
# }

# === 管理面板 ===
download_wbeui() {
    local wbe_file="/root/mihomo"
    local filename="gh-pages.zip"
    local url_xd="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"

    log "正在下载 metacubexd 面板..."

    if ! wget -O "$filename" "$(get_url "$url_xd")"; then
        error "面板下载失败，请检查网络后重试"
        exit 1
    fi

    log "解压面板文件..."
    if ! unzip -oq "$filename"; then
        error "面板解压失败"
        rm -f "$filename"
        exit 1
    fi
    rm -f "$filename"

    local extracted_folder
    extracted_folder=$(find . -maxdepth 1 -type d -name "metacubexd-*" | head -n 1)

    if [ -z "$extracted_folder" ]; then
        error "未找到解压目录"
        exit 1
    fi

    mv "$extracted_folder" "$wbe_file/ui" || {
        error "面板目录移动失败"
        exit 1
    }

    log "面板已安装至 $wbe_file/ui"
}

install_mihomo() {
    local folders="/root/mihomo"

    log "清理旧目录：$folders"
    rm -rf "$folders"
    mkdir -p "$folders" && cd "$folders" || {
        error "无法进入目录 $folders"
        exit 1
    }

    update_system
    check_ip_forward
    download_version
    download_mihomo
    download_service
    download_wbeui
    
    log "恭喜！mihomo 已成功安装完成。"

    echo -e "请手动上传配置文件："
    echo -e "文件名必须为 config.yaml，路径为：${folders}"

    # 清理安装脚本（如果是从 /root/install.sh 执行）
    if [ -f /root/install.sh ]; then
        rm -f /root/install.sh
        log "已删除安装脚本 /root/install.sh"
    fi
}

install_mihomo