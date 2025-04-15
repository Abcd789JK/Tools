#!/bin/bash
#!name = mihomo 一键管理脚本 Beta
#!desc = 管理 & 面板
#!date = 2025-04-15 21:56:39
#!author = ChatGPT

# 当遇到错误或管道错误时立即退出
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
sh_ver="0.0.02"
use_cdn=false
distro="unknown"  # 系统类型：debian, ubuntu, alpine, fedora
arch=""           # 转换后的系统架构
arch_raw=""       # 原始系统架构信息

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
}

#############################
#       网络检测函数       #
#############################
check_network() {
    if ! curl -s --head --fail --connect-timeout 3 -o /dev/null "https://www.google.com"; then
        use_cdn=true
    else
        use_cdn=false
    fi
}

#############################
#       URL 获取函数       #
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
#    检查 mihomo 是否已安装  #
#############################
check_installation() {
    local file="/root/mihomo/mihomo"
    if [ ! -f "$file" ]; then
        echo -e "${red}请先安装 mihomo${reset}"
        start_menu
        return 1
    fi
    return 0
}

#############################
#    Alpine 系统运行状态检测  #
#############################
is_running_alpine() {
    if [ -f "/run/mihomo.pid" ]; then
        pid=$(cat /run/mihomo.pid)
        if [ -d "/proc/$pid" ]; then
            return 0
        fi
    fi
    return 1
}

#############################
#         返回主菜单         #
#############################
start_menu() {
    echo && echo -n -e "${yellow}* 按回车返回主菜单 *${reset}" && read temp
    menu
}

#############################
#         状态显示函数       #
#############################
show_status() {
    local file="/root/mihomo/mihomo"
    local version_file="/root/mihomo/version.txt"
    local install_status run_status auto_start software_version
    distro=$(grep -E '^ID=' /etc/os-release | cut -d= -f2)
    if [ ! -f "$file" ]; then
        install_status="${red}未安装${reset}"
        run_status="${red}未运行${reset}"
        auto_start="${red}未设置${reset}"
        software_version="${red}未安装${reset}"
    else
        install_status="${green}已安装${reset}"
        if [ "$distro" = "alpine" ]; then
            if [ -f "/run/mihomo.pid" ]; then
                pid=$(cat /run/mihomo.pid)
                if [ -d "/proc/$pid" ]; then
                    run_status="${green}已运行${reset}"
                else
                    run_status="${red}未运行${reset}"
                fi
            else
                run_status="${red}未运行${reset}"
            fi
            if rc-status default 2>/dev/null | awk '{print $1}' | grep -qx "mihomo"; then
                auto_start="${green}已设置${reset}"
            else
                auto_start="${red}未设置${reset}"
            fi
        else
            if systemctl is-active --quiet mihomo; then
                run_status="${green}已运行${reset}"
            else
                run_status="${red}未运行${reset}"
            fi
            if systemctl is-enabled --quiet mihomo; then
                auto_start="${green}已设置${reset}"
            else
                auto_start="${red}未设置${reset}"
            fi
        fi
        if [ -f "$version_file" ]; then
            software_version=$(cat "$version_file")
        else
            software_version="${red}未安装${reset}"
        fi
    fi
    echo -e "安装状态：${install_status}"
    echo -e "运行状态：${run_status}"
    echo -e "开机自启：${auto_start}"
    echo -e "脚本版本：${green}${sh_ver}${reset}"
    echo -e "软件版本：${green}${software_version}${reset}"
}

#############################
#      服务管理函数         #
#############################
service_mihomo() {
    check_installation || { start_menu; return; }
    local action="$1"
    local action_text=""
    case "$action" in
        start)   action_text="启动" ;;
        stop)    action_text="停止" ;;
        restart) action_text="重启" ;;
        enable)  action_text="设置开机自启" ;;
        disable) action_text="取消开机自启" ;;
        logs)    action_text="查看日志" ;;
    esac
    if [ "$distro" = "alpine" ]; then
        if [ "$action" == "logs" ]; then
            echo -e "${green}日志查看：请使用 logread 或查看 /var/log/messages${reset}"
            start_menu
            return
        fi
        if [ "$action" == "enable" ]; then
            if rc-update show default | grep -q "mihomo"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update add mihomo default; then
                    echo -e "${green}${action_text}成功${reset}"
                else
                    echo -e "${red}${action_text}失败${reset}"
                fi
            fi
            start_menu
            return
        elif [ "$action" == "disable" ]; then
            if ! rc-update show default | grep -q "mihomo"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update del mihomo; then
                    echo -e "${green}${action_text}成功${reset}"
                else
                    echo -e "${red}${action_text}失败${reset}"
                fi
            fi
            start_menu
            return
        fi
        if [ "$action" == "start" ]; then
            if is_running_alpine; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
                start_menu
                return
            fi
        elif [ "$action" == "stop" ]; then
            if ! is_running_alpine; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
                start_menu
                return
            fi
        fi
        echo -e "${green}正在${action_text}请等待${reset}"
        sleep 1s
        case "$action" in
            start)   rc-service mihomo start ;;
            stop)    rc-service mihomo stop ;;
            restart) rc-service mihomo restart ;;
        esac
        if [ $? -eq 0 ]; then
            echo -e "${green}${action_text}成功${reset}"
        else
            echo -e "${red}${action_text}失败${reset}"
        fi
        start_menu
        return
    fi
    if [ "$action" == "enable" ] || [ "$action" == "disable" ]; then
        local is_enabled=$(systemctl is-enabled --quiet mihomo && echo "enabled" || echo "disabled")
        if { [ "$action" == "enable" ] && [ "$is_enabled" == "enabled" ]; } || \
           { [ "$action" == "disable" ] && [ "$is_enabled" == "disabled" ]; }; then
            echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        else
            echo -e "${green}正在${action_text}请等待${reset}"
            sleep 1s
            if systemctl "$action" mihomo; then
                echo -e "${green}${action_text}成功${reset}"
            else
                echo -e "${red}${action_text}失败${reset}"
            fi
        fi
        start_menu
        return
    fi
    if [ "$action" == "logs" ]; then
        echo -e "${green}正在实时查看 mihomo 日志，按 Ctrl+C 退出${reset}"
        journalctl -u mihomo -o cat -f
        return
    fi
    local service_status=$(systemctl is-active --quiet mihomo && echo "active" || echo "inactive")
    if { [ "$action" == "start" ] && [ "$service_status" == "active" ]; } || \
       { [ "$action" == "stop" ] && [ "$service_status" == "inactive" ]; }; then
        echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        start_menu
        return
    fi
    echo -e "${green}正在${action_text}请等待${reset}"
    sleep 1s
    if systemctl "$action" mihomo; then
        echo -e "${green}${action_text}成功${reset}"
    else
        echo -e "${red}${action_text}失败${reset}"
    fi
    start_menu
}

# 简化操作命令
start_mihomo()   { service_mihomo start; }
stop_mihomo()    { service_mihomo stop; }
restart_mihomo() { service_mihomo restart; }
enable_mihomo()  { service_mihomo enable; }
disable_mihomo() { service_mihomo disable; }
logs_mihomo()    { service_mihomo logs; }

#############################
#        卸载函数          #
#############################
uninstall_mihomo() {
    check_installation || { start_menu; return; }
    local folders="/root/mihomo"
    local shell_file="/usr/bin/mihomo"
    local service_file="/etc/init.d/mihomo"
    local system_file="/etc/systemd/system/mihomo.service"
    read -p "$(echo -e "${red}警告：卸载后将删除当前配置和文件！\n${yellow}确认卸载 mihomo 吗？${reset} (y/n): ")" input
    case "$input" in
        [Yy]* )
            echo -e "${green}mihomo 卸载中请等待${reset}"
            ;;
        [Nn]* )
            echo -e "${yellow}mihomo 卸载已取消${reset}"
            start_menu
            return
            ;;
        * )
            echo -e "${red}无效选择，卸载已取消${reset}"
            start_menu
            return
            ;;
    esac
    sleep 2s
    echo -e "${green}mihomo 卸载命令已发出${reset}"
    if [ "$distro" = "alpine" ]; then
        rc-service mihomo stop 2>/dev/null || { echo -e "${red}停止 mihomo 服务失败${reset}"; exit 1; }
        rc-update del mihomo 2>/dev/null || { echo -e "${red}取消开机自启失败${reset}"; exit 1; }
        rm -f "$service_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    else
        systemctl stop mihomo.service 2>/dev/null || { echo -e "${red}停止 mihomo 服务失败${reset}"; exit 1; }
        systemctl disable mihomo.service 2>/dev/null || { echo -e "${red}禁用 mihomo 服务失败${reset}"; exit 1; }
        rm -f "$system_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    fi
    rm -rf "$folders" || { echo -e "${red}删除相关文件夹失败${reset}"; exit 1; }
    sleep 3s
    if { [ "$distro" = "alpine" ] && [ ! -d "$folders" ]; } || { [ ! -f "$system_file" ] && [ ! -d "$folders" ]; }; then
        echo -e "${green}mihomo 卸载完成${reset}"
        echo ""
        echo -e "卸载成功，如果你想删除此脚本，则退出脚本后，输入 ${green}rm $shell_file -f${reset} 进行删除"
        echo ""
    else
        echo -e "${red}卸载过程中出现问题，请手动检查${reset}"
    fi
    start_menu
}

#############################
#         安装函数         #
#############################
install_mihomo() {
    check_network
    local folders="/root/mihomo"
    local service_file="/etc/init.d/mihomo"
    local system_file="/etc/systemd/system/mihomo.service"
    local install_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/Beta/mihomo/install.sh"
    if [ -d "$folders" ]; then
        echo -e "${yellow}检测到 mihomo 已经安装在 ${folders} 目录下${reset}"
        read -p "$(echo -e "${red}警告：重新安装将删除当前配置和文件！\n是否删除并重新安装？${reset} (y/n): ")" input
        case "$input" in
            [Yy]* )
                echo -e "${green}开始删除，重新安装中请等待${reset}"
                if [ "$distro" = "alpine" ]; then
                    rm -f "$service_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
                else
                    rm -f "$system_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
                fi
                rm -rf "$folders" || { echo -e "${red}删除相关文件夹失败${reset}"; exit 1; }
                ;;
            [Nn]* )
                echo -e "${yellow}取消安装，保持现有安装${reset}"
                start_menu
                return
                ;;
            * )
                echo -e "${red}无效选择，安装已取消${reset}"
                start_menu
                return
                ;;
        esac
    fi
    bash <(curl -Ls "$(get_url "$install_url")")
}

#############################
#      系统架构检测函数      #
#############################
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

#############################
#      版本及更新函数       #
#############################
download_alpha_version() {
    check_network
    local version_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt"
    version=$(curl -sSL "$(get_url "$version_url")") || {
        echo -e "${red}获取 mihomo 远程版本失败${reset}"
        exit 1
    }
}

download_latest_version() {
    local version_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    version=$(curl -sSL "$version_url" | jq -r '.tag_name' | sed 's/v//') || {
        echo -e "${red}获取 mihomo 远程版本失败${reset}"
        exit 1
    }
}

download_shadowsocks() {
    download_version
    local version_file="/root/shadowsocks/version.txt"
    local filename="shadowsocks-v${version}.${arch_raw}-unknown-linux-gnu.tar.xz"
    [ "$distro" = "alpine" ] && filename="shadowsocks-v${version}.${arch_raw}-unknown-linux-musl.tar.xz"
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/${filename}"
    wget -t 3 -T 30 -O "$filename" "$(get_url "$download_url")" || {
        echo -e "${red}shadowsocks 下载失败，请检查网络后重试${reset}"
        exit 1
    }
    tar -xJf "$filename" || {
        echo -e "${red}shadowsocks 解压失败${reset}"
        exit 1
    }
    if [ -f "ssserver" ]; then
        mv "ssserver" shadowsocks
    else
        echo -e "${red}找不到解压后的 ssserver 文件${reset}"
        exit 1
    fi
    rm -f "$filename"
    chmod +x shadowsocks
    echo "$version" > "$version_file"
}

download_latest_mihomo() {
    get_schema
    check_network
    download_latest_version
    local version_file="/root/mihomo/version.txt"
    local filename="mihomo-linux-${arch}-v${version}.gz"
    [ "$arch" = "amd64" ] && filename="mihomo-linux-${arch}-compatible-v${version}.gz"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/v${version}/${filename}"
    wget -t 3 -T 30 -O "$filename" "$(get_url "$download_url")" || {
        echo -e "${red}mihomo 下载失败，可能是网络问题，建议重新运行本脚本重试下载${reset}"
        exit 1
    }
    gunzip "$filename" || {
        echo -e "${red}mihomo 解压失败${reset}"
        exit 1
    }
    mv -f "mihomo-linux-${arch}-compatible-v${version}" mihomo 2>/dev/null || \
    mv -f "mihomo-linux-${arch}-v${version}" mihomo || {
        echo -e "${red}找不到解压后的文件${reset}"
        exit 1
    }
    chmod +x mihomo
    echo "$version" > "$version_file"
}

update_mihomo() {
    check_installation || { start_menu; return; }
    local folders="/root/mihomo"
    local version_file="/root/mihomo/version.txt"
    echo -e "${green}开始检查软件是否有更新${reset}"
    cd "$folders" || exit
    local current_version
    if [ -f "$version_file" ]; then
        current_version=$(cat "$version_file")
    else
        echo -e "${red}请先安装 mihomo${reset}"
        start_menu
        return
    fi
    if [[ "$current_version" == *alpha* ]]; then
        download_version_type="alpha"
    else
        download_version_type="latest"
    fi
    if [ "$download_version_type" == "alpha" ]; then
        download_alpha_version || {
            echo -e "${red}获取最新版本失败，请检查网络或源地址！${reset}"
            start_menu
            return
        }
    else
        download_latest_version || {
            echo -e "${red}获取最新版本失败，请检查网络或源地址！${reset}"
            start_menu
            return
        }
    fi
    local latest_version="$version"
    if [ "$current_version" == "$latest_version" ]; then
        echo -e "${green}当前已是最新，无需更新${reset}"
        start_menu
        return
    fi
    read -p "$(echo -e "${yellow}检查到有更新，是否升级到最新版本？${reset} (y/n): ")" input
    case "$input" in
        [Yy]* )
            echo -e "${green}开始升级，升级中请等待${reset}"
            ;;
        [Nn]* )
            echo -e "${yellow}取消升级，保持现有版本${reset}"
            start_menu
            return
            ;;
        * )
            echo -e "${red}无效选择，升级已取消${reset}"
            start_menu
            return
            ;;
    esac
    if [ "$download_version_type" == "alpha" ]; then
        download_alpha_mihomo || { echo -e "${red}mihomo 下载失败，请重试${reset}"; exit 1; }
    else
        download_latest_mihomo || { echo -e "${red}mihomo 下载失败，请重试${reset}"; exit 1; }
    fi
    sleep 2s
    echo -e "${yellow}更新完成，当前版本已更新为：${reset}【 ${green}${latest_version}${reset} 】"
    service_restart
    start_menu
}

#############################
#       脚本更新函数        #
#############################
update_shell() {
    check_network
    local shell_file="/usr/bin/mihomo"
    local sh_ver_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/Beta/mihomo/mihomo.sh"
    local sh_new_ver=$(curl -sSL "$(get_url "$sh_ver_url")" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
    echo -e "${green}开始检查脚本是否有更新${reset}"
    if [ "$sh_ver" == "$sh_new_ver" ]; then
        echo -e "${green}当前已是最新，无需更新${reset}"
        start_menu
        return
    fi
    read -p "$(echo -e "${yellow}检查到有更新，是否升级到最新版本？${reset} (y/n): ")" input
    case "$input" in
        [Yy]* )
            echo -e "${green}开始升级，升级中请等待${reset}"
            ;;
        [Nn]* )
            echo -e "${yellow}取消升级，保持现有版本${reset}"
            start_menu
            return
            ;;
        * )
            echo -e "${red}无效选择，升级已取消${reset}"
            start_menu
            return
            ;;
    esac
    [ -f "$shell_file" ] && rm "$shell_file"
    wget -t 3 -T 30 -O "$shell_file" "$(get_url "$sh_ver_url")"
    chmod +x "$shell_file"
    hash -r
    echo -e "${yellow}更新完成，当前版本已更新为：${reset}【 ${green}${sh_new_ver}${reset} 】"
    echo -e "${yellow}3 秒后执行新脚本${reset}"
    sleep 3s
    "$shell_file"
}

#############################
#       配置管理函数       #
#############################
config_mihomo() {
    check_installation || { start_menu; return; }
    check_network
    echo -e "${green}开始修改 mihomo 配置${reset}"
    echo -e "${yellow}请选择操作：${reset}"
    echo "1. 新增机场订阅"
    echo "2. 修改机场订阅"
    echo "3. 删除机场订阅"
    read -p "输入选项数字：" choice
    case "$choice" in
        1) add_provider ;;
        2) modify_provider ;;
        3) delete_provider ;;
        *) echo "无效选项"; start_menu ;;
    esac
}

add_provider() {
    local config_file="/root/mihomo/config.yaml"
    if [ ! -f "$config_file" ]; then
        echo -e "${red}配置文件不存在，请检查路径：${config_file}${reset}"
        exit 1
    fi
    local current_count
    current_count=$(grep -c "provider_" "$config_file")
    [ -z "$current_count" ] && current_count=0
    local proxy_providers=""
    local counter=$((current_count + 1))

    while true; do
        read -p "$(echo -e "${yellow}请输入机场的订阅链接: ${reset}")" airport_url
        read -p "$(echo -e "${yellow}请输入机场的名称: ${reset}")" airport_name
        if [ -z "$proxy_providers" ]; then
            proxy_providers="  provider_$(printf "%02d" $counter):
    url: \"${airport_url}\"
    type: http
    interval: 86400
    health-check: {enable: true, url: \"https://www.gstatic.com/generate_204\", interval: 300}
    override:
      additional-prefix: \"[${airport_name}]\""
        else
            proxy_providers="${proxy_providers}
  provider_$(printf "%02d" $counter):
    url: \"${airport_url}\"
    type: http
    interval: 86400
    health-check: {enable: true, url: \"https://www.gstatic.com/generate_204\", interval: 300}
    override:
      additional-prefix: \"[${airport_name}]\""
        fi
        counter=$((counter + 1))
        read -p "$(echo -e "${yellow}是否继续输入订阅, 按回车继续, (输入 n/N 结束): ${reset}")" cont
        [[ "$cont" =~ ^[nN]$ ]] && break
    done

    awk -v new_providers="$proxy_providers" '
    BEGIN { in_pp = 0; inserted = 0; blank_buffer = "" }
    {
        if ($0 ~ /^proxy-providers:/) {
            print $0;
            in_pp = 1;
            next;
        }
        if (in_pp == 1 && $0 ~ /^[[:space:]]*$/) {
            blank_buffer = blank_buffer $0 "\n";
            next;
        }
        if (in_pp == 1 && $0 !~ /^[[:space:]]/) {
            if (inserted == 0) {
                print new_providers;
                print "";
                inserted = 1;
                in_pp = 0;
            }
            print $0;
            next;
        }
        print $0;
    }
    END {
       if (in_pp == 1 && inserted == 0) {
           print new_providers;
           print "";
       }
    }' "$config_file" > temp.yaml && mv temp.yaml "$config_file"

    service_restart
    echo -e "${green}新增完成${reset}"
    start_menu
}

#############################
#       版本切换函数       #
#############################
switch_version() {
    check_installation || { start_menu; return; }
    local folders="/root/mihomo"
    local version_file="/root/mihomo/version.txt"
    cd "$folders" || exit
    local current_version download_version_type
    if [ -f "$version_file" ]; then
        current_version=$(cat "$version_file")
        if [[ "$current_version" == *alpha* ]]; then
            download_version_type="alpha"
        else
            download_version_type="latest"
        fi
    else
        echo -e "${red}请先安装 mihomo${reset}"
        start_menu
        return
    fi
    echo -e "${green}请选择版本${reset}"
    echo -e "${cyan}-------------------------${reset}"
    echo -e "${green}1. 测试版 (Prerelease-Alpha)${reset}"
    echo -e "${green}2. 正式版 (Latest)${reset}"
    echo -e "${cyan}-------------------------${reset}"
    read -p "$(echo -e "${yellow}请输入选项 (1/2): ${reset}")" choice
    case "$choice" in
        1)
            if [ "$download_version_type" == "alpha" ]; then
                echo -e "${yellow}当前已经是测试版，无需重复操作${reset}"
                start_menu
                return
            fi
            echo -e "${yellow}准备切换到测试版${reset}"
            download_alpha_version || { echo -e "${red}获取测试版版本失败，请检查网络或源地址！${reset}"; exit 1; }
            download_alpha_mihomo || { echo -e "${red}测试版安装失败${reset}"; exit 1; }
            echo -e "${yellow}已经切换到测试版${reset}"
            echo -e "${yellow}等待 3 秒后重启生效${reset}"
            sleep 3s
            if [ "$distro" = "alpine" ]; then
                rc-service mihomo restart
            else
                systemctl restart mihomo
            fi
            echo -e "${yellow}当前软件版本${reset}：【 ${green}${version}${reset} 】"
            start_menu
            ;;
        2)
            if [ "$download_version_type" == "latest" ]; then
                echo -e "${yellow}当前已经是正式版，无需重复操作${reset}"
                start_menu
                return
            fi
            echo -e "${yellow}准备切换到正式版${reset}"
            download_latest_version || { echo -e "${red}获取正式版版本失败，请检查网络或源地址！${reset}"; exit 1; }
            download_latest_mihomo || { echo -e "${red}正式版安装失败${reset}"; exit 1; }
            echo -e "${yellow}已经切换到正式版${reset}"
            echo -e "${yellow}等待 3 秒后重启生效${reset}"
            sleep 3s
            service_restart
            echo -e "${yellow}当前软件版本${reset}：【 ${green}v${version}${reset} 】"
            start_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入 1 或 2${reset}"
            start_menu
            return
            ;;
    esac
}

#############################
#           主菜单         #
#############################
menu() {
    clear
    echo "================================="
    echo -e "${green}欢迎使用 mihomo 一键脚本${reset}"
    echo -e "${green}作者：${yellow}ChatGPT JK789${reset}"
    echo -e "${red}使用说明：${reset}"
    echo -e "${red} 1. 更换订阅不能保存原有机场订阅"
    echo -e "${red} 2. 需要全部重新添加机场订阅${reset}"
    echo "================================="
    echo -e "${green} 0${reset}. 更新脚本"
    echo -e "${green}10${reset}. 退出脚本"
    echo -e "${green}20${reset}. 更换订阅"
    echo -e "${green}30${reset}. 查看日志"
    echo "---------------------------------"
    echo -e "${green} 1${reset}. 安装 mihomo"
    echo -e "${green} 2${reset}. 更新 mihomo"
    echo -e "${green} 3${reset}. 卸载 mihomo"
    echo "---------------------------------"
    echo -e "${green} 4${reset}. 启动 mihomo"
    echo -e "${green} 5${reset}. 停止 mihomo"
    echo -e "${green} 6${reset}. 重启 mihomo"
    echo "---------------------------------"
    echo -e "${green} 7${reset}. 添加开机自启"
    echo -e "${green} 8${reset}. 关闭开机自启"
    echo -e "${green} 9${reset}. 切换软件版本"
    echo "================================="
    show_status
    echo "================================="
    read -p "请输入上面选项：" input
    case "$input" in
        1) install_mihomo ;;
        2) update_mihomo ;;
        3) uninstall_mihomo ;;
        4) start_mihomo ;;
        5) stop_mihomo ;;
        6) restart_mihomo ;;
        7) enable_mihomo ;;
        8) disable_mihomo ;;
        9) switch_version ;;
        20) config_mihomo ;;
        30) logs_mihomo ;;
        10) exit 0 ;;
        0) update_shell ;;
        *) echo -e "${red}无效选项，请重新选择${reset}" 
           exit 1 ;;
    esac
}

# 程序入口：先检测系统类型，再进入主菜单
check_distro
menu