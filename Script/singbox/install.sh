#!/bin/bash

# ---------------------------------
# script : singbox 一键安装脚本
# desc   : 安装
# date   : 2025-11-23 11:19:16
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

# 始终更新包列表
echo -e "${cyan}正在更新包列表，请稍候...${reset}"
sudo apt update -qq > /dev/null 2>&1
sudo apt install -y sudo -qq > /dev/null 2>&1

# 检查 sing-box 是否已安装
if command -v sing-box &> /dev/null; then
    echo -e "${cyan}sing-box 已安装，跳过安装步骤${reset}"
else
    # 添加官方 GPG 密钥和仓库
    sudo mkdir -p /etc/apt/keyrings
    sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    sudo chmod a+r /etc/apt/keyrings/sagernet.asc
    echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
" | sudo tee /etc/apt/sources.list.d/sagernet.sources > /dev/null

    # 选择安装稳定版或测试版
    while true; do
        echo -e "${green}1. 稳定版${reset}"
        echo -e "${green}2. 测试版${reset}"
        read -rp "$(echo -e "${yellow}输入数字选择 (1/2): ${reset}")" choice
        case $choice in
            1)
                echo -e "${green}安装稳定版...${reset}"
                sudo apt-get install sing-box -yq > /dev/null 2>&1
                echo -e "${green}安装已完成${reset}"
                break
                ;;
            2)
                echo -e "${green}安装测试版...${reset}"
                sudo apt-get install sing-box-beta -yq > /dev/null 2>&1
                echo -e "${green}安装已完成${reset}"
                break
                ;;
            *)
                echo -e "${red}无效的选择，请输入 1 或 2。${reset}"
                ;;
        esac
    done

    if command -v sing-box &> /dev/null; then
        sing_box_version=$(sing-box version | grep 'sing-box version' | awk '{print $3}')
        echo -e "${cyan}sing-box 安装成功，版本：${reset} $sing_box_version"
         
        # 自动创建 sing-box 用户并设置权限
        if ! id sing-box &>/dev/null; then
            echo -e "${green}正在创建 sing-box 系统用户...${reset}"
            sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
        fi
        echo -e "${green}正在设置 /var/lib/sing-box 和 /etc/sing-box 目录权限...${reset}"
        sudo mkdir -p /var/lib/sing-box
        sudo chown -R sing-box:sing-box /var/lib/sing-box
        sudo chown -R sing-box:sing-box /etc/sing-box
    else
        echo -e "${red}sing-box 安装失败，请检查日志或网络配置${reset}"
    fi
fi
