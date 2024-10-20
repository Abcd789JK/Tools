#!/bin/bash

#!name = mihomo 一键管理脚本
#!desc = 支持，安装、更新、卸载、修改配置等
#!date = 2024-10-18 16:15
#!author = Abcd789JK ChatGPT

set -e -o pipefail

# 颜色代码
Red="\033[31m"  ## 红色
Green="\033[32m"  ## 绿色 
Yellow="\033[33m"  ## 黄色
Blue="\033[34m"  ## 蓝色
Magenta="\033[35m"  ## 洋红
Cyan="\033[36m"  ## 青色
White="\033[37m"  ## 白色
Reset="\033[0m"  ## 黑色

# 定义脚本版本
sh_ver="0.0.5"

# 全局变量路径
FOLDERS="/root/mihomo"
FILE="/root/mihomo/mihomo"
WEB_FILE="/root/mihomo/ui"
SYSCTL_FILE="/etc/sysctl.conf"
CONFIG_FILE="/root/mihomo/config.yaml"
VERSION_FILE="/root/mihomo/version.txt"
SYSTEM_FILE="/etc/systemd/system/mihomo.service"

# 获取本机 IP
GetLocal_ip(){
    # 获取本机的 IPv4 地址
    ipv4=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    # 获取本机的 IPv6 地址
    ipv6=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep 'inet6 ' | awk '{print $2}' | cut -d/ -f1)
}

# 返回主菜单
Start_Main() {
    echo && echo -n -e "${Red}* 按回车返回主菜单 *${Reset}" && read temp
    Main
}

# 检测安装状态
Check_install(){
    if [ ! -f "$FILE" ]; then
        echo -e "${Red}请先安装 mihomo${Reset}"
        Start_Main
    fi
}

# 检查服务状态
Check_status() {
    if pgrep -f "/root/mihomo/mihomo" > /dev/null; then
        status="running"
    else
        status="stopped"
    fi
}

# 获取安装版本
Get_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo -e "${Red}请先安装 mihomo${Reset}"
    fi
}

# 显示脚本版本、服务状态和开机设置
Show_Status() {
    if [ ! -f "$FILE" ]; then
        status="${Red}未安装${Reset}"
        run_status="${Red}未运行${Reset}"
        auto_start="${Red}未设置${Reset}"
    else
        Check_status
        if [ "$status" == "running" ]; then
            status="${Green}已安装${Reset}"
            run_status="${Green}运行中${Reset}"
        else
            status="${Green}已安装${Reset}"
            run_status="${Red}未运行${Reset}"
        fi
        if systemctl is-enabled mihomo.service &>/dev/null; then
            auto_start="${Green}已设置${Reset}"
        else
            auto_start="${Red}未设置${Reset}"
        fi
    fi
    # 显示输出效果
    echo -e "脚本版本：${Green}${sh_ver}${Reset}"
    echo -e "安装状态：${status}"
    echo -e "运行状态：${run_status}"
    echo -e "开机自启：${auto_start}"
}

# 获取当前架构
Get_schema(){
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64')    ARCH='amd64';;
        'x86' | 'i686' | 'i386')     ARCH='386';;
        'aarch64' | 'arm64') ARCH='arm64';;
        'armv7l')   ARCH='armv7';;
        's390x')    ARCH='s390x';;
        *)          echo -e "${Red}不支持的架构：${ARCH_RAW}${Reset}"; exit 1;;
    esac
}

# 启动
Start() {
    # 检测安装状态
    Check_install
    if systemctl is-active --quiet mihomo; then
        echo -e "${Green}mihomo 正在运行中${Reset}"
        Start_Main
    fi
    echo -e "${Green}mihomo 准备启动中${Reset}"
    # 启动服务
    if systemctl start mihomo; then
        echo -e "${Green}mihomo 启动命令已发出${Reset}"
    else
        echo -e "${Red}mihomo 启动失败${Reset}"
        exit 1
    fi
    # 等待服务启动
    sleep 3s
    # 检查服务状态
    if systemctl is-active --quiet mihomo; then
        echo -e "${Green}mihomo 启动成功${Reset}"
    else
        echo -e "${Red}mihomo 启动失败${Reset}"
        exit 1
    fi
    Start_Main
}

# 停止
Stop() {
    # 检测安装状态
    Check_install
    # 检查是否运行
    if ! systemctl is-active --quiet mihomo; then
        echo -e "${Green}mihomo 已经停止${Reset}"
        exit 0
    fi
    echo -e "${Green}mihomo 准备停止中${Reset}"
    # 停止服务
    if systemctl stop mihomo; then
        echo -e "${Green}mihomo 停止命令已发出${Reset}"
    else
        echo -e "${Red}mihomo 停止失败${Reset}"
        exit 1
    fi
    # 等待服务启动
    sleep 3s
    # 检查服务状态
    if systemctl is-active --quiet mihomo; then
        echo -e "${Red}mihomo 停止失败${Reset}"
        exit 1
    else
        echo -e "${Green}mihomo 停止成功${Reset}"
    fi
    Start_Main
}

# 重启
Restart() {
    # 检测安装状态
    Check_install
    echo -e "${Green}mihomo 准备重启中${Reset}"
    # 重启服务
    if systemctl restart mihomo; then
        echo -e "${Green}mihomo 重启命令已发出${Reset}"
    else
        echo -e "${Red}mihomo 重启失败${Reset}"
        exit 1
    fi
    # 等待服务启动
    sleep 3s
    # 检查服务状态
    if systemctl is-active --quiet mihomo; then
        echo -e "${Green}mihomo 重启成功${Reset}"
    else
        echo -e "${Red}mihomo 启动失败${Reset}"
        exit 1
    fi
    Start_Main
}

# 卸载服务
Uninstall() {
    # 检测安装状态
    Check_install
    # 询问是否确认卸载
    read -rp "确认卸载 mihomo 吗？(y/n, 默认n): " confirm
    if [[ -z $confirm || $confirm =~ ^[Nn]$ ]]; then
        echo "卸载已取消。"
        exit 0
    fi
    echo -e "${Green}mihomo 开始卸载${Reset}"
    echo -e "${Green}mihomo 卸载命令已发出${Reset}"
    # 停止服务
    systemctl stop mihomo.service 2>/dev/null || { echo -e "${Red}停止 mihomo 服务失败${Reset}"; exit 1; }
    systemctl disable mihomo.service 2>/dev/null || { echo -e "${Red}禁用 mihomo 服务失败${Reset}"; exit 1; }
    # 删除服务文件
    rm -f "$SYSTEM_FILE" || { echo -e "${Red}删除服务文件失败${Reset}"; exit 1; }
    # 删除相关文件夹
    rm -rf "$FOLDERS" || { echo -e "${Red}删除相关文件夹失败${Reset}"; exit 1; }
    # 重新加载 systemd
    systemctl daemon-reload || { echo -e "${Red}重新加载 systemd 配置失败${Reset}"; exit 1; }
    # 等待服务停止
    sleep 3s
    # 检查卸载是否成功
    if [ ! -f "$SYSTEM_FILE" ] && [ ! -d "$FOLDERS" ]; then
        echo -e "${Green}mihomo 卸载完成${Reset}"
        echo ""
        echo -e "卸载成功，如果你想删除此脚本，则退出脚本后，输入 ${Green}rm /usr/bin/mihomo -f${Reset} 进行删除"
        echo ""
    else
        echo -e "${Red}卸载过程中出现问题，请手动检查${Reset}"
    fi
    exit 0
}

# 更新脚本
Update_Shell() {
    # 获取当前版本
    echo -e "${Green}开始检查是否有更新${Reset}"
    # 获取最新版本号
    sh_ver_url="https://raw.githubusercontent.com/Abcd789JK/Tools/main/Script/mihomo/mihomo.sh"
    sh_new_ver=$(wget --no-check-certificate -qO- "$sh_ver_url" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
    # 最新版本无需更新
    if [ "$sh_ver" == "$sh_new_ver" ]; then
        echo -e "当前版本：[ ${Green}${sh_ver}${Reset} ]"
        echo -e "最新版本：[ ${Green}${sh_new_ver}${Reset} ]"
        echo -e "${Green}当前已是最新版本，无需更新${Reset}"
        Start_Main
    fi
    echo -e "${Green}检查到已有新版本${Reset}"
    echo -e "当前版本：[ ${Green}${sh_ver}${Reset} ]"
    echo -e "最新版本：[ ${Green}${sh_new_ver}${Reset} ]"
    # 开始更新
    while true; do
        read -p "是否升级到最新版本？(y/n)：" confirm
        case $confirm in
            [Yy]* )
                echo -e "开始下载最新版本 [ ${Green}${sh_new_ver}${Reset} ]"
                # 删除旧的 /usr/bin/mihomo 文件
                if [ -f "/usr/bin/mihomo" ]; then
                    rm /usr/bin/mihomo
                fi
                # 下载新的 mihomo 文件并移动到 /usr/bin
                wget -O /usr/bin/mihomo --no-check-certificate "$sh_ver_url"
                # 赋予可执行权限
                chmod +x /usr/bin/mihomo
                # 确保 /usr/bin 在 PATH 中
                if [[ ":$PATH:" != *":/usr/bin:"* ]]; then
                    export PATH=$PATH:/usr/bin
                fi
                # 刷新可执行文件缓存
                hash -r
                echo -e "更新完成，当前版本已更新为 ${Green}[ v${sh_new_ver} ]${Reset}"
                echo -e "5 秒后执行新脚本"
                sleep 5s
                # 执行新脚本
                /usr/bin/mihomo
                break
                ;;
            [Nn]* )
                echo -e "${Red}更新已取消 ${Reset}"
                exit 1
                ;;
            * )
                echo -e "${Red}无效的输入，请输入 y 或 n ${Reset}"
                ;;
        esac
    done
    Start_Main
}

# 安装
Install() {
    # 检测安装状态
    if [ -f "$FILE" ]; then
        echo -e "${Green}mihomo 已安装，请勿重复安装！${Reset}"
        Start_Main
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/Abcd789JK/Tools/main/Script/mihomo/install.sh)
}

# 更新
Update() {
    # 检测安装状态
    Check_install
    echo -e "${Green}开始检查是否有更新${Reset}"
    cd $FOLDERS
    # 获取当前版本
    CURRENT_VERSION=$(Get_version)
    # 获取最新版本
    LATEST_VERSION_URL="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt"
    LATEST_VERSION=$(curl -sSL "$LATEST_VERSION_URL" || { echo -e "${Red}获取版本信息失败${Reset}"; exit 1; })
    # 开始更新
    if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
        echo -e "当前版本：[ ${Green}${CURRENT_VERSION}${Reset} ]"
        echo -e "最新版本：[ ${Green}${LATEST_VERSION}${Reset} ]"
        echo -e "${Green}当前已是最新版本，无需更新${Reset}"
        Start_Main
    fi
    echo -e "${Green}检查到已有新版本${Reset}"
    echo -e "当前版本：[ ${Green}${CURRENT_VERSION}${Reset} ]"
    echo -e "最新版本：[ ${Green}${LATEST_VERSION}${Reset} ]"
    while true; do
        read -p "是否升级到最新版本？(y/n)：" confirm
        case $confirm in
            [Yy]* )
                # 获取架构
                Get_schema
                # 构造文件名
                case "$ARCH" in
                    'arm64' | 'armv7' | 's390x' | '386') FILENAME="mihomo-linux-${ARCH}-${LATEST_VERSION}.gz";;
                    'amd64') FILENAME="mihomo-linux-${ARCH}-compatible-${LATEST_VERSION}.gz";;
                    *)       FILENAME="mihomo-linux-${ARCH}-compatible-${LATEST_VERSION}.gz";;
                esac
                # 开始下载
                DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/${FILENAME}"
                echo -e "开始下载最新版本：[ ${Green}${LATEST_VERSION}${Reset} ]"
                # 等待3秒
                sleep 3s
                wget -t 3 -T 30 "${DOWNLOAD_URL}" -O "${FILENAME}" || { echo -e "${Red}下载失败${Reset}"; exit 1; }
                echo -e "[ ${Green}${LATEST_VERSION}${Reset} ] 下载完成，开始更新"
                # 解压文件
                gunzip "$FILENAME" || { echo -e "${Red}解压失败${Reset}"; exit 1; }
                # 重命名
                if [ -f "mihomo-linux-${ARCH}-${LATEST_VERSION}" ]; then
                    mv "mihomo-linux-${ARCH}-${LATEST_VERSION}" mihomo
                elif [ -f "mihomo-linux-${ARCH}-compatible-${LATEST_VERSION}" ]; then
                    mv "mihomo-linux-${ARCH}-compatible-${LATEST_VERSION}" mihomo
                else
                    echo -e "${Red}找不到下载后的文件${Reset}"
                    exit 1
                fi
                # 授权
                chmod 755 mihomo
                # 更新版本信息
                echo "$LATEST_VERSION" > "$VERSION_FILE"
                # 重新加载
                systemctl daemon-reload
                # 重启
                systemctl restart mihomo
                echo -e "更新完成，当前版本已更新为：[ ${Green}${LATEST_VERSION}${Reset} ]"
                # 检查并显示服务状态
                if systemctl is-active --quiet mihomo; then
                    echo -e "当前状态：[ ${Green}运行中${Reset} ]"
                else
                    echo -e "当前状态：[ ${Red}未运行${Reset} ]"
                    Start_Main
                fi
                Start_Main
                ;;
            [Nn]* )
                echo -e "${Red}更新已取消${Reset}"
                Start_Main
                ;;
            * )
                echo -e "${Red}无效的输入，请输入 y 或 n${Reset}"
                ;;
        esac
    done
    Start_Main
}

# 配置
Configure() {
    # 检测安装状态
    Check_install
    # 配置文件 URL
    CONFIG_URL="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Config/mihomo.yaml"
    # 下载配置文件
    curl -s -o "$CONFIG_FILE" "$CONFIG_URL"
    # 获取用户输入的机场数量，默认为 1，且限制为 5 个以内
    while true; do
        read -p "请输入需要配置的机场数量（默认 1 个，最多 5 个）：" airport_count
        airport_count=${airport_count:-1}
        # 验证输入是否为 1 到 5 之间的正整数
        if [[ "$airport_count" =~ ^[0-9]+$ ]] && [ "$airport_count" -ge 1 ] && [ "$airport_count" -le 5 ]; then
            break
        else
            echo -e "${Red}无效的数量，请输入 1 到 5 之间的正整数。${Reset}"
        fi
    done
    # 初始化 proxy-providers 部分
    proxy_providers="proxy-providers:"
    # 动态添加机场
    for ((i=1; i<=airport_count; i++))
    do
        read -p "请输入第 $i 个机场的订阅连接：" airport_url
        read -p "请输入第 $i 个机场的名称：" airport_name
        
        proxy_providers="$proxy_providers
  Airport_0$i:
    <<: *pr
    url: \"$airport_url\"
    override:
      additional-prefix: \"[$airport_name]\""
    done
    # 使用 awk 将 proxy-providers 插入到指定位置
    awk -v providers="$proxy_providers" '
    /^# 机场配置/ {
        print
        print providers
        next
    }
    { print }
    ' "$CONFIG_FILE" > temp.yaml && mv temp.yaml "$CONFIG_FILE"
    # 提示保存位置
    echo -e "mihomo 配置已完成并保存到 ${CONFIG_FILE} 文件夹"
    # 重新加载 systemd
    systemctl daemon-reload
    systemctl start mihomo
    systemctl enable mihomo
    echo -e "${Green}已设置开机自启动${Reset}"
    # 调用函数获取
    GetLocal_ip
    # 引导语
    echo -e ""
    echo -e "恭喜你，你的 mihomo 已经配置完成"
    echo -e "${Magenta}=========================${Reset}"
    echo -e "mihomo 管理面板地址"
    echo -e "${Green}http://$ipv4:9090/ui ${Reset}"
    echo -e "${White}-------------------------${Reset}"
    echo -e "${Yellow}mihomo          进入菜单 ${Reset}"
    echo -e "${Cyan}=========================${Reset}"
    # 返回主菜单
    Start_Main
}

# 面板配置
Panel(){
    # 检测安装状态
    Check_install
    # 管理面板 URL
    WEB_URL1="https://github.com/MetaCubeX/Yacd-meta.git"
    WEB_URL2="https://github.com/metacubex/metacubexd.git"
    WEB_URL3="https://github.com/MetaCubeX/Razord-meta.git"
    # 检查是否已安装
    if [ -d "$WEB_FILE" ]; then
        echo -e "${Yellow}检测到面板已安装。${Reset}"
        while true; do
            read -rp "是否替换当前安装的面板？(y/n, 默认[y]): " replace
            replace=${replace:-y}
            case "$replace" in
                [Yy]* ) 
                    echo -e "${Green}开始替换面板${Reset}"
                    rm -rf "$WEB_FILE"
                    break
                    ;;
                [Nn]* )
                    echo -e "${Yellow}保留当前面板安装，退出。${Reset}"
                    Start_Main
                    ;;
                *) echo -e "${Red}请输入 y 或 n。${Reset}" ;;
            esac
        done
    fi
    # 选择模式
    while true; do
        echo -e "请选择面板："
        echo -e "${Green}1${Reset}. Yacd 面板"
        echo -e "${Green}2${Reset}. metacubexd 面板"
        echo -e "${Green}3${Reset}. dashboard 魔改版面板"
        read -rp "输入数字选择协议 (1-4 默认[1]): " confirm
        confirm=${confirm:-1}  # 默认为 1
        case "$confirm" in
            1) 
                WEB_URL="$WEB_URL1"
                PANEL_NAME="Yacd 面板"
                break
                ;;
            2) 
                WEB_URL="$WEB_URL2"
                PANEL_NAME="metacubexd 面板"
                break
                ;;
            3) 
                WEB_URL="$WEB_URL3"
                PANEL_NAME="dashboard 魔改版面板"
                break
                ;;
            *) echo -e "${Red}无效的选择，请输入 1、2、3 或 4。${Reset}" ;;
        esac
    done
    # 确认选择的面板名称
    echo -e "你选择的是：${Green} $PANEL_NAME ${Reset}"
    # 开始下载
    echo -e "${Green}开始下载 mihomo 管理面板${Reset}"
    # 检查 URL 是否为空
    if [ -z "$WEB_URL" ]; then
        echo -e "${Red}错误：仓库 URL 为空！请检查选择逻辑。${Reset}"
        exit 1
    fi
    # 下载仓库
    git clone "$WEB_URL" -b gh-pages "$WEB_FILE"
    echo -e "${Green} $PANEL_NAME 安装成功${Reset}"
    # 返回主菜单
    Start_Main
}

# 主菜单
Main() {
    clear
    echo "================================="
    echo -e "${Green}欢迎使用 mihomo 一键脚本 Beta 版${Reset}"
    echo -e "${Green}作者：${Yellow} GPT ${Reset}"
    echo -e "${Red}请保证科学上网已经开启${Reset}"
    echo -e "${Red}安装过程中可以按 ctrl+c 强制退出${Reset}"
    echo "================================="
    echo -e "${Green} 0${Reset}. 更新脚本"
    echo "---------------------------------"
    echo -e "${Green} 1${Reset}. 安装 mihomo"
    echo -e "${Green} 2${Reset}. 更新 mihomo"
    echo -e "${Green} 3${Reset}. 卸载 mihomo"
    echo "---------------------------------"
    echo -e "${Green} 4${Reset}. 启动 mihomo"
    echo -e "${Green} 5${Reset}. 停止 mihomo"
    echo -e "${Green} 6${Reset}. 重启 mihomo"
    echo "---------------------------------"
    echo -e "${Green} 7${Reset}. 更换订阅"
    echo -e "${Green} 8${Reset}. 更换面板"
    echo -e "${Green}10${Reset}. 退出脚本"
    echo "================================="
    Show_Status
    echo "================================="
    read -p "请输入选项[0-8]：" num
    case "$num" in
        1) Install ;;
        2) Update ;;
        3) Uninstall ;;
        4) Start ;;
        5) Stop ;;
        6) Restart ;;
        7) Configure ;;
        8) Panel ;;
        10) exit 0 ;;
        0) Update_Shell ;;
        *) echo -e "${Red}无效选项，请重新选择${Reset}" 
           exit 1 ;;
    esac
}

# 启动主菜单
Main
