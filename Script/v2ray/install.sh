#!/bin/bash
#!name = v2ray 一键安装脚本
#!desc = 安装 & 配置
#!date = 2025-04-26 14:59:18
#!author = ChatGPT

# 终止脚本执行遇到错误时退出，并启用管道错误检测
set -e -o pipefail

#############################
#         颜色变量         #
#############################
red="\033[31m"    # 红色
green="\033[32m"  # 绿色
yellow="\033[33m" # 黄色
blue="\033[34m"   # 蓝色
cyan="\033[36m"   # 青色
reset="\033[0m"   # 重置颜色

#############################
#       全局变量定义       #
#############################
sh_ver="1.0.0"    # 脚本版本
use_cdn=false     # 代理加速
distro="unknown"  # 系统类型
arch=""           # 系统架构
arch_raw=""       # 原始架构信息

#############################
#       系统检测函数       #
#############################
check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                distro="$ID"
                pkg_update="apt update && apt upgrade -y"
                pkg_install="apt install -y"
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl daemon-reload; systemctl start v2ray; }
                ;;
            alpine)
                distro="alpine"
                pkg_update="apk update && apk upgrade"
                pkg_install="apk add"
                service_enable() { rc-update add v2ray default; }
                service_restart() { rc-service v2ray restart; }
                ;;
            fedora)
                distro="fedora"
                pkg_update="dnf upgrade --refresh -y"
                pkg_install="dnf install -y"
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl daemon-reload; systemctl start v2ray; }
                ;;
            arch)
                distro="arch"
                pkg_update="pacman -Syu --noconfirm"
                pkg_install="pacman -S --noconfirm"
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl daemon-reload; systemctl start v2ray; }
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
}

#############################
#       网络检测函数       #
#############################
check_network() {
    if ! curl -sI --connect-timeout 1 https://www.google.com > /dev/null; then
        use_cdn=true
    fi
}

#############################
#        URL 处理函数       #
#############################
get_url() {
    local url=$1
    local final_url
    if [ "$use_cdn" = true ]; then
        final_url="https://gh-proxy.com/$url"
        if ! curl --silent --head --fail --connect-timeout 3 -L "$final_url" -o /dev/null; then
            final_url="https://github.boki.moe/$url"
        fi
    else
        final_url="$url"
    fi
    if ! curl --silent --head --fail --connect-timeout 3 -L "$final_url" -o /dev/null; then
        echo -e "${red}连接失败，可能是网络或代理站点不可用，请检查后重试！${reset}" >&2
        return 1
    fi
    echo "$final_url"
}

#############################
#    系统更新及安装函数    #
#############################
update_system() {
    eval "$pkg_update"
    eval "$pkg_install curl git gzip wget nano iptables tzdata jq unzip"
}

#############################
#     系统架构检测函数     #
#############################
get_schema() {
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64)
            arch="64"
            ;;
        x86|i686|i386)
            arch="32"
            ;;
        aarch64|arm64)
            arch="arm64-v8a"
            ;;
        armv7|armv7l)
            arch="arm32-v7a"
            ;;
        s390x)
            arch="s390x"
            ;;
        *)
            echo -e "${red}不支持的架构：${arch_raw}${reset}"
            exit 1
            ;;
    esac
}

#############################
#      远程版本获取函数     #
#############################
download_version() {
    local version_url="https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
    version=$(curl -sSL "$version_url" | jq -r '.tag_name' | sed 's/v//') || {
        echo -e "${red}获取 v2ray 远程版本失败${reset}";
        exit 1;
    }
}

#############################
#     v2ray 下载函数      #
#############################
download_v2ray() {
    download_version
    local version_file="/root/v2ray/version.txt"
    local filename="v2ray-linux-${arch}.zip"
    local download_url="https://github.com/v2fly/v2ray-core/releases/download/v${version}/${filename}"
    wget -t 3 -T 30 -O "$filename" "$(get_url "$download_url")" || {
        echo -e "${red}v2ray 下载失败，请检查网络后重试${reset}"
        exit 1
    }
    unzip "$filename" && rm "$filename" || { 
        echo -e "${red}v2ray 解压失败${reset}"
        exit 1
    }
    chmod +x v2ray
    echo "$version" > "$version_file"
}

#############################
#   系统服务配置下载函数    #
#############################
download_service() {
    if [ "$distro" = "alpine" ]; then
        local service_file="/etc/init.d/v2ray"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/v2ray.openrc"
        wget -t 3 -T 30 -O "$service_file" "$(get_url "$service_url")" || {
            echo -e "${red}系统服务下载失败，请检查网络后重试${reset}"
            exit 1
        }
        chmod +x "$service_file"
        service_enable
    else
        local service_file="/etc/systemd/system/v2ray.service"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/v2ray.service"
        wget -t 3 -T 30 -O "$service_file" "$(get_url "$service_url")" || {
            echo -e "${red}系统服务下载失败，请检查网络后重试${reset}"
            exit 1
        }
        chmod +x "$service_file"
        service_enable
    fi
}

#############################
#    管理脚本下载函数      #
#############################
download_shell() {
    local shell_file="/usr/bin/v2ray"
    local sh_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/v2ray/v2ray.sh"
    [ -f "$shell_file" ] && rm -f "$shell_file"
    wget -t 3 -T 30 -O "$shell_file" "$(get_url "$sh_url")" || {
        echo -e "${red}管理脚本下载失败，请检查网络后重试${reset}"
        exit 1
    }
    chmod +x "$shell_file"
    hash -r
}

#############################
#       安装主流程函数      #
#############################
config_v2ray() {
    local config_file="/root/v2ray/config.json"
    local config_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Config/v2ray.json"
    wget -t 3 -T 30 -q -O "$config_file" "$(get_url "$config_url")" || { 
        echo -e "${red}配置文件下载失败${reset}"
        exit 1
    }
    echo -e "${green}开始配置 v2ray ${reset}"
    read -rp "是否快速生成配置文件？(y/n 默认[y]): " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" == [Yy] ]]; then
        echo -e "请选择协议："
        echo -e "${green}1${reset}、vmess+tcp"
        echo -e "${green}2${reset}、vmess+ws"
        echo -e "${green}3${reset}、vmess+tcp+tls"
        echo -e "${green}4${reset}、vmess+ws+tls"
        read -rp "输入数字选择协议 (1-4 默认[1]): " confirm
        confirm=${confirm:-1}
        PORT=$(shuf -i 10000-65000 -n 1)
        UUID=$(cat /proc/sys/kernel/random/uuid)
        if [[ "$confirm" == "2" || "$confirm" == "4" ]]; then
            WS_PATH=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
        fi
        echo -e "配置文件已生成："
        case $confirm in
            1) echo -e "  - 协议: ${green}vmess+tcp${reset}" ;;
            2) echo -e "  - 协议: ${green}vmess+ws${reset}" ;;
            3) echo -e "  - 协议: ${green}vmess+tcp+tls${reset}" ;;
            4) echo -e "  - 协议: ${green}vmess+ws+tls${reset}" ;;
            *) echo -e "${red}无效选项${reset}" && exit 1 ;;
        esac
        echo -e "  - 端口: ${green}$PORT${reset}"
        echo -e "  - UUID: ${green}$UUID${reset}"
        if [[ "$confirm" == "2" || "$confirm" == "4" ]]; then
            echo -e "  - WS路径: ${green}/$WS_PATH${reset}"
        fi
    else
        echo -e "请选择协议："
        echo -e "${green}1${reset}、vmess+tcp"
        echo -e "${green}2${reset}、vmess+ws"
        echo -e "${green}3${reset}、vmess+tcp+tls"
        echo -e "${green}4${reset}、vmess+ws+tls"
        read -rp "输入数字选择协议 (1-4 默认[1]): " confirm
        confirm=${confirm:-1}
        read -p "请输入监听端口 (留空以随机生成端口): " PORT
        if [[ -z "$PORT" ]]; then
            PORT=$(shuf -i 10000-65000 -n 1)
        elif [[ "$PORT" -lt 10000 || "$PORT" -gt 65000 ]]; then
            echo -e "${red}端口号必须在10000到65000之间。${reset}"
            exit 1
        fi
        read -p "请输入 v2ray UUID (留空以生成随机UUID): " UUID
        if [[ -z "$UUID" ]]; then
            UUID=$(cat /proc/sys/kernel/random/uuid)
        fi
        if [[ "$confirm" == "2" || "$confirm" == "4" ]]; then
            read -p "请输入 WebSocket 路径 (留空以生成随机路径): " WS_PATH
            if [[ -z "$WS_PATH" ]]; then
                WS_PATH=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
            else
                WS_PATH="${WS_PATH#/}"
            fi
        fi
        echo -e "配置文件已生成："
        case $confirm in
            1) echo -e "  - 协议: ${green}vmess+tcp${reset}" ;;
            2) echo -e "  - 协议: ${green}vmess+ws${reset}" ;;
            3) echo -e "  - 协议: ${green}vmess+tcp+tls${reset}" ;;
            4) echo -e "  - 协议: ${green}vmess+ws+tls${reset}" ;;
            *) echo -e "${red}无效选项${reset}" && exit 1 ;;
        esac
        echo -e "  - 端口: ${green}$PORT${reset}"
        echo -e "  - UUID: ${green}$UUID${reset}"
        if [[ "$confirm" == "2" || "$confirm" == "4" ]]; then
            echo -e "  - WS路径: ${green}/$WS_PATH${reset}"
        fi
    fi
    echo -e "${green}读取配置文件${reset}"
    config=$(cat "$config_file")
    echo -e "${green}修改配置文件${reset}"
    case $confirm in
        1)  # vmess + tcp
            config=$(echo "$config" | jq --arg port "$PORT" --arg uuid "$UUID" '
                .inbounds[0].port = ($port | tonumber) |
                .inbounds[0].settings.clients[0].id = $uuid |
                .inbounds[0].streamSettings.network = "tcp" |
                del(.inbounds[0].streamSettings.wsSettings) |
                del(.inbounds[0].streamSettings.tlsSettings)
            ')
            ;;
        2)  # vmess + ws
            config=$(echo "$config" | jq --arg port "$PORT" --arg uuid "$UUID" --arg ws_path "/$WS_PATH" '
                .inbounds[0].port = ($port | tonumber) |
                .inbounds[0].settings.clients[0].id = $uuid |
                .inbounds[0].streamSettings.network = "ws" |
                .inbounds[0].streamSettings.wsSettings.path = $ws_path |
                del(.inbounds[0].streamSettings.tlsSettings) |
                del(.inbounds[0].streamSettings.wsSettings.headers)
            ')
            ;;
        3)  # vmess + tcp + tls
            config=$(echo "$config" | jq --arg port "$PORT" --arg uuid "$UUID" '
                .inbounds[0].port = ($port | tonumber) |
                .inbounds[0].settings.clients[0].id = $uuid |
                .inbounds[0].streamSettings.network = "tcp" |
                .inbounds[0].streamSettings.security = "tls" |
                .inbounds[0].streamSettings.tlsSettings = {
                    "certificates": [
                        {
                            "certificateFile": "/root/ssl/server.crt",
                            "keyFile": "/root/ssl/server.key"
                        }
                    ]
                }
            ')
            ;;
        4)  # vmess + ws + tls
            config=$(echo "$config" | jq --arg port "$PORT" --arg uuid "$UUID" --arg ws_path "/$WS_PATH" '
                .inbounds[0].port = ($port | tonumber) |
                .inbounds[0].settings.clients[0].id = $uuid |
                .inbounds[0].streamSettings.network = "ws" |
                .inbounds[0].streamSettings.wsSettings.path = $ws_path |
                .inbounds[0].streamSettings.security = "tls" |
                .inbounds[0].streamSettings.tlsSettings = {
                    "certificates": [
                        {
                            "certificateFile": "/root/ssl/server.crt",
                            "keyFile": "/root/ssl/server.key"
                        }
                    ]
                } |
                del(.inbounds[0].streamSettings.wsSettings.headers)
            ')
            ;;
        *)
            echo -e "${red}无效选项${reset}"
            exit 1
            ;;
    esac
    echo -e "${green}写入配置文件${reset}"
    echo "$config" > "$config_file"
    echo -e "${green}验证修改后的配置文件格式${reset}"
    if ! jq . "$config_file" >/dev/null 2>&1; then
        echo -e "${red}修改后的配置文件格式无效，请检查文件${reset}"
        exit 1
    fi
    service_restart
    echo -e "${green}v2ray 配置已完成并保存到 ${config_file} 文件夹${reset}"
    echo -e "${green}v2ray 配置完成，正在启动中${reset}"
    echo -e "${red}管理命令${reset}"
    echo -e "${cyan}=========================${reset}"
    echo -e "${green}命令: v2ray 进入管理菜单${reset}"
    echo -e "${cyan}=========================${reset}"
    echo -e "${green}v2ray 已成功启动并设置为开机自启${reset}"
}

#############################
#       安装主流程函数      #
#############################

install_v2ray() {
    local folders="/root/v2ray"
    [ -d "$folders" ] && rm -rf "$folders"
    mkdir -p "$folders" && cd "$folders" 
    check_distro
    echo -e "${yellow}当前系统版本：${reset}[ ${green}${distro}${reset} ]"
    get_schema
    echo -e "${yellow}当前系统架构：${reset}[ ${green}${arch_raw}${reset} ]"
    download_version
    echo -e "${yellow}当前软件版本：${reset}[ ${green}${version}${reset} ]"
    download_v2ray
    download_service
    download_shell
    echo -e "${green}恭喜你! v2ray 已经安装完成${reset}"
    echo -e "${red}输入 y/Y 生产配置文件${reset}"
    read -p "$(echo -e "${yellow}请输入选择(y/n) [默认: y]: ${reset}")" confirm
    confirm=${confirm:-y}
    case "$confirm" in
        [Yy]*)
            config_v2ray
            ;;
        [Nn]*)
            echo -e "${green}跳过配置文件下载${reset}"
            ;;
         *)
            echo -e "${red}无效选择，跳过配置文件下载，需自己手动上传${reset}"
            ;;
    esac
    rm -f /root/install.sh
}

#############################
#           主流程          #
#############################
check_distro
check_network
update_system
install_v2ray