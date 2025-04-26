#!/bin/bash
#!name = v2ray 一键管理脚本 Beta
#!desc = 管理 & 面板
#!date = 2025-04-26 08:52:49
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
sh_ver="0.0.03"
use_cdn=false
distro="unknown"  # 系统类型
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
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl restart v2ray; }
                ;;
            alpine)
                distro="alpine"
                service_enable() { rc-update add v2ray default; }
                service_restart() { rc-service v2ray restart; }
                ;;
            fedora)
                distro="fedora"
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl restart v2ray; }
                ;;
            arch)
                distro="arch"
                service_enable() { systemctl enable v2ray; }
                service_restart() { systemctl restart v2ray; }
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
#    检查 v2ray 是否已安装  #
#############################
check_installation() {
    local file="/root/v2ray/v2ray"
    if [ ! -f "$file" ]; then
        echo -e "${red}请先安装 v2ray${reset}"
        start_menu
        return 1
    fi
    return 0
}

#############################
#    Alpine 系统运行状态检测  #
#############################
is_running_alpine() {
    if [ -f "/run/v2ray.pid" ]; then
        pid=$(cat /run/v2ray.pid)
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
    local file="/root/v2ray/v2ray"
    local version_file="/root/v2ray/version.txt"
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
            if [ -f "/run/v2ray.pid" ]; then
                pid=$(cat /run/v2ray.pid)
                if [ -d "/proc/$pid" ]; then
                    run_status="${green}已运行${reset}"
                else
                    run_status="${red}未运行${reset}"
                fi
            else
                run_status="${red}未运行${reset}"
            fi
            if rc-status default 2>/dev/null | awk '{print $1}' | grep -qx "v2ray"; then
                auto_start="${green}已设置${reset}"
            else
                auto_start="${red}未设置${reset}"
            fi
        else
            if systemctl is-active --quiet v2ray; then
                run_status="${green}已运行${reset}"
            else
                run_status="${red}未运行${reset}"
            fi
            if systemctl is-enabled --quiet v2ray; then
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
service_v2ray() {
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
            if rc-update show default | grep -q "v2ray"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update add v2ray default; then
                    echo -e "${green}${action_text}成功${reset}"
                else
                    echo -e "${red}${action_text}失败${reset}"
                fi
            fi
            start_menu
            return
        elif [ "$action" == "disable" ]; then
            if ! rc-update show default | grep -q "v2ray"; then
                echo -e "${yellow}已${action_text}，无需重复操作${reset}"
            else
                echo -e "${green}正在${action_text}请等待${reset}"
                sleep 1s
                if rc-update del v2ray; then
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
            start)   rc-service v2ray start ;;
            stop)    rc-service v2ray stop ;;
            restart) rc-service v2ray restart ;;
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
        local is_enabled=$(systemctl is-enabled --quiet v2ray && echo "enabled" || echo "disabled")
        if { [ "$action" == "enable" ] && [ "$is_enabled" == "enabled" ]; } || \
           { [ "$action" == "disable" ] && [ "$is_enabled" == "disabled" ]; }; then
            echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        else
            echo -e "${green}正在${action_text}请等待${reset}"
            sleep 1s
            if systemctl "$action" v2ray; then
                echo -e "${green}${action_text}成功${reset}"
            else
                echo -e "${red}${action_text}失败${reset}"
            fi
        fi
        start_menu
        return
    fi
    if [ "$action" == "logs" ]; then
        echo -e "${green}正在实时查看 v2ray 日志，按 Ctrl+C 退出${reset}"
        journalctl -u v2ray -o cat -f
        return
    fi
    local service_status=$(systemctl is-active --quiet v2ray && echo "active" || echo "inactive")
    if { [ "$action" == "start" ] && [ "$service_status" == "active" ]; } || \
       { [ "$action" == "stop" ] && [ "$service_status" == "inactive" ]; }; then
        echo -e "${yellow}已${action_text}，无需重复操作${reset}"
        start_menu
        return
    fi
    echo -e "${green}正在${action_text}请等待${reset}"
    sleep 1s
    if systemctl "$action" v2ray; then
        echo -e "${green}${action_text}成功${reset}"
    else
        echo -e "${red}${action_text}失败${reset}"
    fi
    start_menu
}

# 简化操作命令
start_v2ray()   { service_v2ray start; }
stop_v2ray()    { service_v2ray stop; }
restart_v2ray() { service_v2ray restart; }
enable_v2ray()  { service_v2ray enable; }
disable_v2ray() { service_v2ray disable; }
logs_v2ray()    { service_v2ray logs; }

#############################
#        卸载函数          #
#############################
uninstall_v2ray() {
    check_installation || { start_menu; return; }
    local folders="/root/v2ray"
    local shell_file="/usr/bin/v2ray"
    local service_file="/etc/init.d/v2ray"
    local system_file="/etc/systemd/system/v2ray.service"
    read -p "$(echo -e "${red}警告：卸载后将删除当前配置和文件！\n${yellow}确认卸载 v2ray 吗？${reset} (y/n): ")" input
    case "$input" in
        [Yy]* )
            echo -e "${green}v2ray 卸载中请等待${reset}"
            ;;
        [Nn]* )
            echo -e "${yellow}v2ray 卸载已取消${reset}"
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
    echo -e "${green}v2ray 卸载命令已发出${reset}"
    if [ "$distro" = "alpine" ]; then
        rc-service v2ray stop 2>/dev/null || { echo -e "${red}停止 v2ray 服务失败${reset}"; exit 1; }
        rc-update del v2ray 2>/dev/null || { echo -e "${red}取消开机自启失败${reset}"; exit 1; }
        rm -f "$service_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    else
        systemctl stop v2ray.service 2>/dev/null || { echo -e "${red}停止 v2ray 服务失败${reset}"; exit 1; }
        systemctl disable v2ray.service 2>/dev/null || { echo -e "${red}禁用 v2ray 服务失败${reset}"; exit 1; }
        rm -f "$system_file" || { echo -e "${red}删除服务文件失败${reset}"; exit 1; }
    fi
    rm -rf "$folders" || { echo -e "${red}删除相关文件夹失败${reset}"; exit 1; }
    sleep 3s
    if { [ "$distro" = "alpine" ] && [ ! -d "$folders" ]; } || { [ ! -f "$system_file" ] && [ ! -d "$folders" ]; }; then
        echo -e "${green}v2ray 卸载完成${reset}"
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
install_v2ray() {
    check_network
    local folders="/root/v2ray"
    local service_file="/etc/init.d/v2ray"
    local system_file="/etc/systemd/system/v2ray.service"
    local install_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/Beta/v2ray/install.sh"
    if [ -d "$folders" ]; then
        echo -e "${yellow}检测到 v2ray 已经安装在 ${folders} 目录下${reset}"
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
    local version_url="https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
    version=$(curl -sSL "$version_url" | jq -r '.tag_name' | sed 's/v//') || {
        echo -e "${red}获取 v2ray 远程版本失败${reset}";
        exit 1;
    }
}

download_v2ray() {
    get_schema
    check_network
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

update_v2ray() {
    check_installation || { start_menu; return; }
    local folders="/root/v2ray"
    local version_file="/root/v2ray/version.txt"
    echo -e "${green}开始检查软件是否有更新${reset}"
    cd "$folders" || exit
    local current_version
    if [ -f "$version_file" ]; then
        current_version=$(cat "$version_file")
    else
        echo -e "${red}请先安装 v2ray${reset}"
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
    download_v2ray|| { 
        echo -e "${red}v2ray 下载失败，请重试${reset}"
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
    local shell_file="/usr/bin/v2ray"
    local sh_ver_url="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/Beta/v2ray/v2ray.sh"
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
config_v2ray() {
    check_installation || { start_menu; return; }
    local config_file="/root/v2ray/config.json"
    echo -e "${green}开始修改 v2ray 配置${reset}"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${red}配置文件不存在，请检查路径：${config_file}${reset}"
        exit 1
    fi

    select_protocol() {
        echo -e "请选择加密协议："
        echo -e "${green}1${reset}. vmess+tcp"
        echo -e "${green}2${reset}. vmess+ws"
        echo -e "${green}3${reset}. vmess+tcp+tls"
        echo -e "${green}4${reset}. vmess+ws+tls"
        read -rp "输入数字选择协议 (1-4 默认[1]): " confirm
        confirm=${confirm:-1}
        case $confirm in
            1) method="vmess+tcp" ;;
            2) method="vmess+ws" ;;
            3) method="vmess+tcp+tls" ;;
            4) method="vmess+ws+tls" ;;
            *) method="vmess+tcp" ;;
        esac
    }

    get_random_port() {
        shuf -i 10000-65000 -n 1
    }

    get_random_uuid() {
        if command -v uuidgen &>/dev/null; then
            uuidgen
        else
            cat /proc/sys/kernel/random/uuid
        fi
    }

    get_random_ws_path() {
        local length=${1:-10}
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    }

    generate_or_input() {
        read -rp "是否快速生成端口和密码？(Y/n 默认[Y]): " quick
        quick=${quick,,}

        if [[ "$quick" =~ ^(y|)$ ]]; then
            port=$(get_random_port)
            uuid=$(get_random_uuid)
            [[ "$confirm" == "2" || "$confirm" == "4" ]] && ws_path="/$(get_random_ws_path 12)"
        else
            while :; do
                read -rp "请输入监听端口 (10000-65000, 回车随机): " port
                if [[ -z "$port" ]]; then
                    port=$(get_random_port)
                    break
                elif [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 10000 && port <= 65000 )); then
                    break
                else
                    echo "端口范围必须在 10000 到 65000 之间。"
                fi
            done

            read -rp "请输入 v2ray 的 UUID (回车随机 UUID): " uuid
            uuid=${uuid:-$(get_random_uuid)}

            [[ "$confirm" == "2" || "$confirm" == "4" ]] && {
                read -rp "请输入 WebSocket 路径 (回车随机): " ws_path_input
                ws_path="/${ws_path_input:-$(get_random_ws_path 10)}"
            }
        fi
    }

    echo -e "请选择配置修改模式："
    echo -e "  ${green}1${reset}. 生成新的配置"
    echo -e "  ${green}2${reset}. 单独修改一项"
    read -rp "输入数字选择模式 (1-2 默认[1]): " moua
    moua=${moua:-1}

    local config current_config current_port current_uuid current_network current_ws_path current_security new_config

    if [[ "$moua" == "1" ]]; then
        read -rp "是否快速生成配置文件？(y/n 默认[y]): " mode
        mode=${mode:-y}
        select_protocol
        generate_or_input
        config=$(<"$config_file")
        case $confirm in
            1)
                config=$(echo "$config" | jq --arg port "$port" --arg uuid "$uuid" '
                    .inbounds[0].port = ($port | tonumber) |
                    .inbounds[0].settings.clients[0].id = $uuid |
                    .inbounds[0].streamSettings.network = "tcp" |
                    del(.inbounds[0].streamSettings.wsSettings) |
                    del(.inbounds[0].streamSettings.tlsSettings) |
                    del(.inbounds[0].streamSettings.security)
                ') ;;
            2)
                config=$(echo "$config" | jq --arg port "$port" --arg uuid "$uuid" --arg ws_path "$ws_path" '
                    .inbounds[0].port = ($port | tonumber) |
                    .inbounds[0].settings.clients[0].id = $uuid |
                    .inbounds[0].streamSettings.network = "ws" |
                    .inbounds[0].streamSettings.wsSettings.path = $ws_path |
                    del(.inbounds[0].streamSettings.tlsSettings) |
                    del(.inbounds[0].streamSettings.wsSettings.headers) |
                    del(.inbounds[0].streamSettings.security)
                ') ;;
            3)
                config=$(echo "$config" | jq --arg port "$port" --arg uuid "$uuid" '
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
                ') ;;
            4)
                config=$(echo "$config" | jq --arg port "$port" --arg uuid "$uuid" --arg ws_path "$ws_path" '
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
                ') ;;
            *)
                echo -e "${red}无效选项${reset}"
                start_menu ;;
        esac
    elif [[ "$moua" == "2" ]]; then
        current_config=$(<"$config_file")
        current_port=$(echo "$current_config" | jq -r '.inbounds[0].port')
        current_uuid=$(echo "$current_config" | jq -r '.inbounds[0].settings.clients[0].id')
        current_network=$(echo "$current_config" | jq -r '.inbounds[0].streamSettings.network')
        current_ws_path=""
        [[ "$current_network" == "ws" ]] && current_ws_path=$(echo "$current_config" | jq -r '.inbounds[0].streamSettings.wsSettings.path')
        current_security=$(echo "$current_config" | jq -r '.inbounds[0].streamSettings.security // empty')

        case "$current_network+$current_security" in
            "ws+tls") method="vmess+ws+tls" ;;
            "ws+") method="vmess+ws" ;;
            "tcp+tls") method="vmess+tcp+tls" ;;
            *) method="vmess+tcp" ;;
        esac

        echo -e "请选择要修改的项："
        echo -e "${green}1${reset}、端口"
        echo -e "${green}2${reset}、UUID"
        [[ -n "$current_ws_path" ]] && echo -e "${green}3${reset}、路径"
        read -rp "输入数字选择 (默认[1]): " moub
        moub=${moub:-1}

        case $moub in
            1)
                read -rp "请输入新的端口 (回车随机): " port
                port=${port:-$(get_random_port)}
                (( port < 10000 || port > 65000 )) && {
                    echo -e "${red}端口号必须在10000到65000之间。${reset}"
                    exit 1
                }
                new_config=$(echo "$current_config" | jq --arg port "$port" '.inbounds[0].port = ($port | tonumber)')
                uuid="$current_uuid" ;;
            2)
                read -rp "请输入新的 UUID (回车随机): " uuid
                uuid=${uuid:-$(get_random_uuid)}
                new_config=$(echo "$current_config" | jq --arg uuid "$uuid" '.inbounds[0].settings.clients[0].id = $uuid')
                port="$current_port" ;;
            3)
                read -rp "请输入新的 WebSocket 路径 (回车随机): " ws_path
                ws_path="/${ws_path:-$(get_random_ws_path 10)}"
                new_config=$(echo "$current_config" | jq --arg ws_path "$ws_path" '.inbounds[0].streamSettings.wsSettings.path = $ws_path')
                port="$current_port"
                uuid="$current_uuid" ;;
            *)
                echo -e "${red}无效选项${reset}"
                exit 1 ;;
        esac
        config="$new_config"
    else
        echo -e "${red}无效的修改模式${reset}"
        exit 1
    fi

    echo -e "${green}更新后的配置:${reset}"
    echo -e "端口: ${green}${port}${reset}"
    echo -e "密码: ${green}${uuid}${reset}"
    echo -e "类型: ${green}${method}${reset}"
    [[ "$confirm" == "2" || "$confirm" == "4" || "$method" == *"ws"* ]] && echo -e "路径: ${green}${ws_path}${reset}"

    echo -e "${green}正在更新配置文件${reset}"
    echo "$config" > "$config_file"
    if ! jq . "$config_file" >/dev/null 2>&1; then
        echo -e "${red}配置格式错误，更新失败${reset}"
        exit 1
    fi

    echo -e "${green}恭喜你！修改成功${reset}"
    service_restart
    start_menu
}

#############################
#           主菜单         #
#############################
menu() {
    clear
    echo "================================="
    echo -e "${green}欢迎使用 v2ray 一键脚本 Beta 版${reset}"
    echo -e "${green}作者：${yellow}ChatGPT JK789${reset}"
    echo "================================="
    echo -e "${green} 0${reset}. 更新脚本"
    echo -e "${green}10${reset}. 退出脚本"
    echo -e "${green}20${reset}. 更换配置"
    echo -e "${green}30${reset}. 查看日志"
    echo "---------------------------------"
    echo -e "${green} 1${reset}. 安装 v2ray"
    echo -e "${green} 2${reset}. 更新 v2ray"
    echo -e "${green} 3${reset}. 卸载 v2ray"
    echo "---------------------------------"
    echo -e "${green} 4${reset}. 启动 v2ray"
    echo -e "${green} 5${reset}. 停止 v2ray"
    echo -e "${green} 6${reset}. 重启 v2ray"
    echo "---------------------------------"
    echo -e "${green} 7${reset}. 添加开机自启"
    echo -e "${green} 8${reset}. 关闭开机自启"
    echo "================================="
    show_status
    echo "================================="
    read -p "请输入上面选项：" input
    case "$input" in
        1) install_v2ray ;;
        2) update_v2ray ;;
        3) uninstall_v2ray ;;
        4) start_v2ray ;;
        5) stop_v2ray ;;
        6) restart_v2ray ;;
        7) enable_v2ray ;;
        8) disable_v2ray ;;
        20) config_v2ray ;;
        30) logs_v2ray ;;
        10) exit 0 ;;
        0) update_shell ;;
        *) echo -e "${red}无效选项，请重新选择${reset}" 
           exit 1 ;;
    esac
}

# 程序入口：先检测系统类型，再进入主菜单
check_distro
menu