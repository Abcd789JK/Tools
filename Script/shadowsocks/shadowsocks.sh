#!/bin/bash
#!name = ss 一键管理脚本
#!desc = 管理 & 面板
#!date = 2025-04-14 16:04:22
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
sh_ver="0.0.2"
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
                service_enable() { systemctl enable shadowsocks; }
                service_restart() { systemctl daemon-reload; systemctl start shadowsocks; }
                ;;
            alpine)
                distro="alpine"
                service_enable() { rc-update add shadowsocks default; }
                service_restart() { rc-service shadowsocks restart; }
                ;;
            fedora)
                distro="fedora"
                service_enable() { systemctl enable shadowsocks; }
                service_restart() { systemctl daemon-reload; systemctl start shadowsocks; }
                ;;
            arch)
                distro="arch"
                service_enable() { systemctl enable shadowsocks; }
                service_restart() { systemctl daemon-reload; systemctl start shadowsocks; }
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
#    检查 shadowsocks 是否已安装  #
#############################
check_installation() {
    local file="/root/shadowsocks/shadowsocks"
    if [ ! -f "$file" ]; then
        echo -e "${red}请先安装 shadowsocks${reset}"
        start_menu
        return 1
    fi
    return 0
}

#############################
#    Alpine 系统运行状态检测  #
#############################
is_running_alpine() {
    if [ -f "/run/shadowsocks.pid" ]; then
        pid=$(cat /run/shadowsocks.pid)
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
    local file="/root/shadowsocks/shadowsocks"
    local version_file="/root/shadowsocks/version.txt"
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
            if [ -f "/run/shadowsocks.pid" ]; then
                pid=$(cat /run/shadowsocks.pid)
                if [ -d "/proc/$pid" ]; then
                    run_status="${green}已运行${reset}"
                else
                    run_status="${red}未运行${reset}"
                fi
            else
                run_status="${red}未运行${reset}"
            fi
            if rc-status default 2>/dev/null | awk '{print $1}' | grep -qx "shadowsocks"; then
                auto_start="${green}已设置${reset}"
            else
                auto_start="${red}未设置${reset}"
            fi
        else
            if systemctl is-active --quiet shadowsocks; then
                run_status="${green}已运行${reset}"
            else
                run_status="${red}未运行${reset}"
            fi
            if systemctl is-enabled --quiet shadowsocks; then
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
service_shadowsocks() {
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
            if rc-update show default | grep -q "shadowsocks"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update add shadowsocks default; then
                    echo -e "${green}${action_text}成功${reset}"
                else
                    echo -e "${red}${action_text}失败${reset}"
                fi
            fi
            start_menu
            return
        elif [ "$action" == "disable" ]; then
            if ! rc-update show default | grep -q "shadowsocks"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update del shadowsocks; then
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
            start)   rc-service shadowsocks start ;;
            stop)    rc-service shadowsocks stop ;;
            restart) rc-service shadowsocks restart ;;
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
        local is_enabled=$(systemctl is-enabled --quiet shadowsocks && echo "enabled" || echo "disabled")
        if { [ "$action" == "enable" ] && [ "$is_enabled" == "enabled" ]; } || \
           { [ "$action" == "disable" ] && [ "$is_enabled" == "disabled" ]; }; then
            echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        else
            echo -e "${green}正在${action_text}请等待${reset}"
            sleep 1s
            if systemctl "$action" shadowsocks; then
                echo -e "${green}${action_text}成功${reset}"
            else
                echo -e "${red}${action_text}失败${reset}"
            fi
        fi
        start_menu
        return
    fi
    if [ "$action" == "logs" ]; then
        echo -e "${green}正在实时查看 shadowsocks 日志，按 Ctrl+C 退出${reset}"
        journalctl -u shadowsocks -o cat -f
        return
    fi
    local service_status=$(systemctl is-active --quiet shadowsocks && echo "active" || echo "inactive")
    if { [ "$action" == "start" ] && [ "$service_status" == "active" ]; } || \
       { [ "$action" == "stop" ] && [ "$service_status" == "inactive" ]; }; then
        echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        start_menu
        return
    fi
    echo -e "${green}正在${action_text}请等待${reset}"
    sleep 1s
    if systemctl "$action" shadowsocks; then
        echo -e "${green}${action_text}成功${reset}"
    else
        echo -e "${red}${action_text}失败${reset}"
    fi
    start_menu
}

# 简化操作命令
start_shadowsocks()   { service_shadowsocks start; }
stop_shadowsocks()    { service_shadowsocks stop; }
restart_shadowsocks() { service_shadowsocks restart; }
enable_shadowsocks()  { service_shadowsocks enable; }
disable_shadowsocks() { service_shadowsocks disable; }
logs_shadowsocks()    { service_shadowsocks logs; }

#############################
#        卸载函数          #
#############################
uninstall_shadowsocks() {
    check_installation || { start_menu; return; }
    local folders="/root/shadowsocks"
    local shell_file="/usr/bin/ss"
    local service_file="/etc/init.d/shadowsocks"
    local system_file="/etc/systemd/system/shadowsocks.service"
    read -p "$(echo -e "${red}警告：卸载后将删除当前配置和文件！\n${yellow}确认卸载 shadowsocks 吗？${reset} (y/n): ")" input
    case "$input" in
        [Yy]* )
            echo -e "${green}shadowsocks 卸载中请等待${reset}"
            ;;
        [Nn]* )
            echo -e "${yellow}shadowsocks 卸载已取消${reset}"
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
    echo -e "${green}shadowsocks 卸载命令已发出${reset}"
    if [ "$distro" = "alpine" ]; then
        rc-service shadowsocks stop 2>/dev/null || { echo -e "${red}停止 shadowsocks 服务失败${reset}"; exit 1; }
        rc-update del shadowsocks 2>/dev/null || { echo -e "${red}取消开机自启失败${reset}"; exit 1; }
        rm -f "$service_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    else
        systemctl stop shadowsocks.service 2>/dev/null || { echo -e "${red}停止 shadowsocks 服务失败${reset}"; exit 1; }
        systemctl disable shadowsocks.service 2>/dev/null || { echo -e "${red}禁用 shadowsocks 服务失败${reset}"; exit 1; }
        rm -f "$system_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    fi
    rm -rf "$folders" || { echo -e "${red}删除相关文件夹失败${reset}"; exit 1; }
    sleep 3s
    if { [ "$distro" = "alpine" ] && [ ! -d "$folders" ]; } || { [ ! -f "$system_file" ] && [ ! -d "$folders" ]; }; then
        echo -e "${green}shadowsocks 卸载完成${reset}"
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
install_shadowsocks() {
    check_network
    local folders="/root/shadowsocks"
    local service_file="/etc/init.d/shadowsocks"
    local system_file="/etc/systemd/system/shadowsocks.service"
    local install_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/shadowsocks/install.sh"
    if [ -d "$folders" ]; then
        echo -e "${yellow}检测到 shadowsocks 已经安装在 ${folders} 目录下${reset}"
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
            arch='64'
            ;;
        x86|i686|i386)
            arch='32'
            ;;
        aarch64|arm64)
            arch='arm64-v8a'
            ;;
        armv7|armv7l)
            arch='arm32-v7a'
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
#      远程版本获取函数     #
#############################
download_version() {
    local version_url="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    version=$(curl -sSL "$version_url" | jq -r '.tag_name' | sed 's/v//') || {
        echo -e "${red}获取 shadowsocks 远程版本失败${reset}";
        exit 1;
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

update_shadowsocks() {
    check_installation || { start_menu; return; }
    local folders="/root/shadowsocks"
    local version_file="/root/shadowsocks/version.txt"
    echo -e "${green}开始检查软件是否有更新${reset}"
    cd "$folders" || exit
    local current_version
    if [ -f "$version_file" ]; then
        current_version=$(cat "$version_file")
    else
        echo -e "${red}请先安装 shadowsocks${reset}"
        start_menu
        return
    fi
    download_version || {
        echo -e "${red}获取最新版本失败，请检查网络或源地址！${reset}"
        start_menu
         return
    }
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
    download_shadowsocks|| { 
        echo -e "${red}shadowsocks 下载失败，请重试${reset}"
        exit 1
    }
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
    local shell_file="/usr/bin/ssr"
    local sh_ver_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/shadowsocks/shadowsocks.sh"
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
config_shadowsocks() {
    local config_file="/root/shadowsocks/config.json"
    local config_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Config/shadowsocks.json"
    wget -t 3 -T 30 -q -O "$config_file" "$(get_url "$config_url")" || { 
        echo -e "${red}配置文件下载失败${reset}"
        exit 1
    }
    echo -e "${green}开始配置 Shadowsocks ${reset}"
    
    # 提示是否快速生成配置文件
    read -rp "是否快速生成配置文件？(y/n 默认[y]): " quick_confirm
    quick_confirm=${quick_confirm:-y}
    
    if [[ "$quick_confirm" == [Yy] ]]; then
        # 自动随机生成端口
        PORT=$(shuf -i 10000-65000 -n 1)
        
        # 选择加密方式
        echo -e "请选择加密方式："
        echo -e "${green}1${reset}、aes-128-gcm"
        echo -e "${green}2${reset}、aes-256-gcm"
        echo -e "${green}3${reset}、chacha20-ietf-poly1305"
        echo -e "${green}4${reset}、2022-blake3-aes-128-gcm"
        echo -e "${green}5${reset}、2022-blake3-aes-256-gcm"
        echo -e "${green}6${reset}、2022-blake3-chacha20-ietf-poly1305"
        read -rp "输入数字选择加密方式 (1-6 默认[1]): " method_choice
        method_choice=${method_choice:-1}
        case $method_choice in
            1) METHOD="aes-128-gcm" ;;
            2) METHOD="aes-256-gcm" ;;
            3) METHOD="chacha20-ietf-poly1305" ;;
            4) METHOD="2022-blake3-aes-128-gcm" ;;
            5) METHOD="2022-blake3-aes-256-gcm" ;;
            6) METHOD="2022-blake3-chacha20-ietf-poly1305" ;;         
            *) METHOD="aes-128-gcm" ;;
        esac

        # 选择认证方式：自定义密码或自动生成 UUID
        echo -e "请选择认证模式："
        echo -e "${green}1${reset}、自定义密码"
        echo -e "${green}2${reset}、自动生成 UUID 当作密码"
        read -rp "输入数字选择认证模式 (1-2 默认[1]): " auth_choice
        auth_choice=${auth_choice:-1}
        if [[ "$auth_choice" == "1" ]]; then
            read -rp "请输入 Shadowsocks 密码 (留空则自动生成 UUID): " PASSWORD
            if [[ -z "$PASSWORD" ]]; then
                PASSWORD=$(cat /proc/sys/kernel/random/uuid)
            fi
        else
            PASSWORD=$(cat /proc/sys/kernel/random/uuid)
        fi
    else
        # 手动模式：用户输入端口、加密方式以及认证信息
        read -p "请输入监听端口 (留空以随机生成端口): " PORT
        if [[ -z "$PORT" ]]; then
            PORT=$(shuf -i 10000-65000 -n 1)
        elif [[ "$PORT" -lt 10000 || "$PORT" -gt 65000 ]]; then
            echo -e "${red}端口号必须在10000到65000之间。${reset}"
            exit 1
        fi
        
        echo -e "请选择加密方式："
        echo -e "${green}1${reset}、aes-128-gcm"
        echo -e "${green}2${reset}、aes-256-gcm"
        echo -e "${green}3${reset}、chacha20-ietf-poly1305"
        echo -e "${green}4${reset}、2022-blake3-aes-128-gcm"
        echo -e "${green}5${reset}、2022-blake3-aes-256-gcm"
        echo -e "${green}6${reset}、2022-blake3-chacha20-ietf-poly1305"
        read -rp "输入数字选择加密方式 (1-6 默认[1]): " method_choice
        method_choice=${method_choice:-1}
        case $method_choice in
            1) METHOD="aes-128-gcm" ;;
            2) METHOD="aes-256-gcm" ;;
            3) METHOD="chacha20-ietf-poly1305" ;;
            4) METHOD="2022-blake3-aes-128-gcm" ;;
            5) METHOD="2022-blake3-aes-256-gcm" ;;
            6) METHOD="2022-blake3-chacha20-ietf-poly1305" ;;         
            *) METHOD="aes-128-gcm" ;;
        esac
        
        echo -e "请选择认证模式："
        echo -e "${green}1${reset}、自定义密码"
        echo -e "${green}2${reset}、自动生成 UUID 当作密码"
        read -rp "输入数字选择认证模式 (1-2 默认[2]): " auth_choice
        auth_choice=${auth_choice:-1}
        if [[ "$auth_choice" == "2" ]]; then
            read -rp "请输入 Shadowsocks 密码 (留空则自动生成 UUID): " PASSWORD
            if [[ -z "$PASSWORD" ]]; then
                PASSWORD=$(cat /proc/sys/kernel/random/uuid)
            fi
        else
            PASSWORD=$(cat /proc/sys/kernel/random/uuid)
        fi
    fi

    echo -e "${green}生成的配置参数如下：${reset}"
    echo -e "  - 端口: ${green}$PORT${reset}"
    echo -e "  - 加密方式: ${green}$METHOD${reset}"
    echo -e "  - 密码: ${green}$PASSWORD${reset}"

    echo -e "${green}读取配置文件模板${reset}"
    config=$(cat "$config_file")
    echo -e "${green}修改配置文件${reset}"
    config=$(echo "$config" | jq --arg port "$PORT" --arg password "$PASSWORD" --arg method "$METHOD" '
        .server_port = ($port | tonumber) |
        .password = $password |
        .method = $method
    ')
    
    echo -e "${green}写入配置文件${reset}"
    echo "$config" > "$config_file"
    
    echo -e "${green}验证修改后的配置文件格式${reset}"
    if ! jq . "$config_file" >/dev/null 2>&1; then
        echo -e "${red}修改后的配置文件格式无效，请检查文件${reset}"
        exit 1
    fi
    
    service_restart
    start_menu
}

#############################
#       获取配置函数       #
#############################
get_shadowsocks() {
    local config_file="/root/shadowsocks/config.json"
    # 提取端口、加密方式和密码
    server_port=$(jq -r '.server_port' "$config_file")
    method=$(jq -r '.method' "$config_file")
    password=$(jq -r '.password' "$config_file")
    # 输出
    echo "🔑 端口：$server_port"
    echo "🔐 加密方式：$method"
    echo "🔑 密码：$password"
}

#############################
#           主菜单         #
#############################
menu() {
    clear
    echo "================================="
    echo -e "${green}欢迎使用 shadowsocks 一键脚本 Beta 版${reset}"
    echo -e "${green}作者：${yellow}ChatGPT JK789${reset}"
    echo "================================="
    echo -e "${green} 0${reset}. 更新脚本"
    echo -e "${green}10${reset}. 退出脚本"
    echo -e "${green}20${reset}. 更换配置"
    echo -e "${green}30${reset}. 查看日志"
    echo "---------------------------------"
    echo -e "${green} 1${reset}. 安装 shadowsocks"
    echo -e "${green} 2${reset}. 更新 shadowsocks"
    echo -e "${green} 3${reset}. 卸载 shadowsocks"
    echo "---------------------------------"
    echo -e "${green} 4${reset}. 启动 shadowsocks"
    echo -e "${green} 5${reset}. 停止 shadowsocks"
    echo -e "${green} 6${reset}. 重启 shadowsocks"
    echo "---------------------------------"
    echo -e "${green} 7${reset}. 添加开机自启"
    echo -e "${green} 8${reset}. 关闭开机自启"
    echo "================================="
    show_status
    echo "================================="
    read -p "请输入上面选项：" input
    case "$input" in
        1) install_shadowsocks ;;
        2) update_shadowsocks ;;
        3) uninstall_shadowsocks ;;
        4) start_shadowsocks ;;
        5) stop_shadowsocks ;;
        6) restart_shadowsocks ;;
        7) enable_shadowsocks ;;
        8) disable_shadowsocks ;;
        20) config_shadowsocks ;;
        30) logs_shadowsocks ;;
        40) get_shadowsocks ;;
        10) exit 0 ;;
        0) update_shell ;;
        *) echo -e "${red}无效选项，请重新选择${reset}" 
           exit 1 ;;
    esac
}

# 程序入口：先检测系统类型，再进入主菜单
check_distro
menu