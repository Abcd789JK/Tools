#!/bin/bash
#!name = sing-box 一键安装脚本
#!desc = 安装 & 配置
#!date = 2025-06-07 17:19:51
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
                service_enable() { systemctl enable sing-box; }
                service_restart() { systemctl daemon-reload; systemctl start sing-box; }
                ;;
            alpine)
                distro="alpine"
                pkg_update="apk update && apk upgrade"
                pkg_install="apk add"
                service_enable() { rc-update add sing-box default; }
                service_restart() { rc-service sing-box restart; }
                ;;
            fedora)
                distro="fedora"
                pkg_update="dnf upgrade --refresh -y"
                pkg_install="dnf install -y"
                service_enable() { systemctl enable sing-box; }
                service_restart() { systemctl daemon-reload; systemctl start sing-box; }
                ;;
            arch)
                distro="arch"
                pkg_update="pacman -Syu --noconfirm"
                pkg_install="pacman -S --noconfirm"
                service_enable() { systemctl enable sing-box; }
                service_restart() { systemctl daemon-reload; systemctl start sing-box; }
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
            arch="amd64"
            ;;
        x86|i686|i386)
            arch="386"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7|armv7l)
            arch="arm7"
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
    local version_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    version=$(curl -sSL "$version_url" | jq -r '.tag_name' | sed 's/v//') || {
        echo -e "${red}获取 sing-box 远程版本失败${reset}";
        exit 1;
    }
}

#############################
#     sing-box 下载函数      #
#############################
download_sing-box() {
    download_version
    local version_file="/root/sing-box/version.txt"
    local filename="sing-box-${version}-linux-${arch}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${filename}"
    wget -O "$filename" "$(get_url "$download_url")" || {
        echo -e "${red}sing-box 下载失败，请检查网络后重试${reset}"
        exit 1
    }
    tar -xvzf "$filename" && rm "$filename" || { 
        echo -e "${red}sing-box 解压失败${reset}"
        exit 1
    }
    chmod +x sing-box
    echo "$version" > "$version_file"
}

#############################
#   系统服务配置下载函数    #
#############################
download_service() {
    if [ "$distro" = "alpine" ]; then
        local service_file="/etc/init.d/sing-box"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/sing-box.openrc"
        wget -O "$service_file" "$(get_url "$service_url")" || {
            echo -e "${red}系统服务下载失败，请检查网络后重试${reset}"
            exit 1
        }
        chmod +x "$service_file"
        service_enable
    else
        local service_file="/etc/systemd/system/sing-box.service"
        local service_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Service/sing-box.service"
        wget -O "$service_file" "$(get_url "$service_url")" || {
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
    local shell_file="/usr/bin/sing-box"
    local sh_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/sing-box/sing-box.sh"
    [ -f "$shell_file" ] && rm -f "$shell_file"
    wget -O "$shell_file" "$(get_url "$sh_url")" || {
        echo -e "${red}管理脚本下载失败，请检查网络后重试${reset}"
        exit 1
    }
    chmod +x "$shell_file"
    hash -r
}

#############################
#       安装主流程函数      #
#############################
config_sing-box() {
    local config_file="/root/sing-box/config.json"
    local config_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Config/sing-box.json"
    wget -O "$config_file" "$(get_url "$config_url")" || { 
        echo -e "${red}配置文件下载失败${reset}"
        exit 1
    }
    service_restart
    echo -e "${green}sing-box 配置已完成并保存到 ${config_file} 文件夹${reset}"
    echo -e "${green}sing-box 配置完成，正在启动中${reset}"
    echo -e "${red}管理命令${reset}"
    echo -e "${cyan}=========================${reset}"
    echo -e "${green}命令: sing-box 进入管理菜单${reset}"
    echo -e "${cyan}=========================${reset}"
    echo -e "${green}sing-box 已成功启动并设置为开机自启${reset}"
}

#############################
#       安装主流程函数      #
#############################

install_sing-box() {
    local folders="/root/sing-box"
    [ -d "$folders" ] && rm -rf "$folders"
    mkdir -p "$folders" && cd "$folders" 
    check_distro
    echo -e "${yellow}当前系统版本：${reset}[ ${green}${distro}${reset} ]"
    get_schema
    echo -e "${yellow}当前系统架构：${reset}[ ${green}${arch_raw}${reset} ]"
    download_version
    echo -e "${yellow}当前软件版本：${reset}[ ${green}${version}${reset} ]"
    download_sing-box
    download_service
    download_shell
    echo -e "${green}恭喜你! sing-box 已经安装完成${reset}"
    echo -e "${red}输入 y/Y 生产配置文件${reset}"
    read -p "$(echo -e "${yellow}请输入选择(y/n) [默认: y]: ${reset}")" confirm
    confirm=${confirm:-y}
    case "$confirm" in
        [Yy]*)
            config_sing-box
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
install_sing-box