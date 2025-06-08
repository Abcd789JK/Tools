#!/bin/bash

# ---------------------------------
# script : sing-box 一键管理脚本
# desc   : 管理 & 面板
# date   : 2025-06-08 11:07:07
# author : ChatGPT
# ---------------------------------

# --- 配置参数 ---


# --- 函数定义 ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "本脚本需要以 root 用户执行，请使用 sudo 或以 root 用户执行。"
        exit 1
    fi
}

# 安装 sing-box（如果未安装）
install_sing-box() {
    if ! command -v sing-box &> /dev/null; then
        echo "安装 sing-box..."
        curl -fsSL https://sing-box.app/install.sh | sh
        if [[ $? -ne 0 ]]; then
            echo "sing-box 安装失败，请检查错误信息并重试。"
            exit 1
        fi
    fi
}